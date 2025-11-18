#!/bin/bash

# =============================================
# 共享缓冲区配置（所有单位均为字节）
# =============================================

# Core0 配置
CORE0_BASE_ADDR=0x2580C000
CORE0_BUFFER_SIZE=8192          # 2048个int × 4 = 8192字节
CORE0_RP_ADDR=0x28100084
CORE0_WP_ADDR=0x28100080

# Core1 配置（在Core0基础上偏移）
CORE1_BASE_OFFSET=0x10000       # Core1基地址偏移
CORE1_POINTER_OFFSET=0x38        # 14个int × 4 = 56字节 = 0x38

CORE1_BASE_ADDR=$(printf "0x%X" $((CORE0_BASE_ADDR + CORE1_BASE_OFFSET)))
CORE1_BUFFER_SIZE=8192           # 与Core0大小相同
CORE1_RP_ADDR=$(printf "0x%X" $((CORE0_RP_ADDR + CORE1_POINTER_OFFSET)))
CORE1_WP_ADDR=$(printf "0x%X" $((CORE0_WP_ADDR + CORE1_POINTER_OFFSET)))

# 输出文件
OUTPUT_PREFIX="dump_tpu_fifo"
CORE0_OUTPUT_FILE="${OUTPUT_PREFIX}_core0.bin"
CORE1_OUTPUT_FILE="${OUTPUT_PREFIX}_core1.bin"

# =============================================
# 函数：调试信息输出
# =============================================
debug_echo() {
    if [ "${DEBUG:-0}" -eq 1 ]; then
        echo "[DEBUG] $1"
    fi
}

# =============================================
# 函数：安全检查
# =============================================
check_environment() {
    # 检查busybox
    if ! command -v busybox > /dev/null 2>&1; then
        echo "错误: 未找到busybox工具"
        return 1
    fi
    
    # 检查/dev/mem访问权限
    if [ ! -e /dev/mem ]; then
        echo "错误: /dev/mem设备不存在"
        return 1
    fi
    
    if [ ! -r /dev/mem ]; then
        echo "错误: 没有读取/dev/mem的权限"
        return 1
    fi
    
    return 0
}

# =============================================
# 函数：安全读取内存
# =============================================
safe_devmem_read() {
    local addr=$1
    local bits=$2
    local value
    local retry=0
    local max_retries=3
    
    while [ $retry -lt $max_retries ]; do
        if value=$(busybox devmem $addr $bits 2>/dev/null); then
            echo $value
            return 0
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt $max_retries ]; then
            debug_echo "读取地址 $(printf "0x%08X" $addr) 失败，重试 $retry/$max_retries"
            sleep 0.1
        fi
    done
    
    echo "错误: 无法读取地址 $(printf "0x%08X" $addr)" >&2
    return 1
}

# =============================================
# 函数：读取连续数据块（优化版）
# =============================================
read_data_block() {
    local core_name=$1
    local base_addr=$2
    local start_offset=$3
    local data_size=$4
    local output_file=$5
    
    local bytes_read=0
    local current_offset=$start_offset
    local batch_size=1024  # 每次读取的批次大小
    
    # 计算需要读取的批次数量
    local total_batches=$(( (data_size + batch_size - 1) / batch_size ))
    local current_batch=0
    
    while [ $bytes_read -lt $data_size ]; do
        local remaining=$((data_size - bytes_read))
        local current_batch_size=$((remaining < batch_size ? remaining : batch_size))
        
        # 读取一个批次的数据
        for ((i=0; i<current_batch_size; i++)); do
            local current_addr=$((base_addr + current_offset))
            
            # 使用8位读取避免对齐问题
            local value=$(safe_devmem_read $current_addr 8)
            if [ $? -ne 0 ]; then
                echo "错误: 读取地址 $(printf "0x%08X" $current_addr) 失败"
                return 1
            fi
            
            # 写入输出文件
            printf "\\x$(printf "%02X" $value)" >> "$output_file"
            
            current_offset=$(( (current_offset + 1) ))
            bytes_read=$((bytes_read + 1))
        done
        
        current_batch=$((current_batch + 1))
        local percent=$((bytes_read * 100 / data_size))
        
        # 显示进度
        printf "\r%s 进度: %d/%d 字节 (%d%%)" "$core_name" $bytes_read $data_size $percent
    done
    
    echo ""  # 换行
    return 0
}

# =============================================
# 函数：读取共享缓冲区
# =============================================
read_shared_buffer() {
    local core_name=$1
    local base_addr=$2
    local buffer_size=$3
    local rp_addr=$4
    local wp_addr=$5
    local output_file=$6
    
    echo ""
    echo "=========================================="
    echo "读取 $core_name 共享缓冲区"
    echo "=========================================="
    
    # 读取RP和WP指针（这些是int单位的偏移量）
    echo "读取指针寄存器..."
    RP_OFFSET_INT=$(safe_devmem_read $rp_addr 32)
    if [ $? -ne 0 ]; then
        echo "错误: 读取RP指针失败"
        return 1
    fi
    
    WP_OFFSET_INT=$(safe_devmem_read $wp_addr 32)
    if [ $? -ne 0 ]; then
        echo "错误: 读取WP指针失败"
        return 1
    fi
    
    # 转换为十进制
    RP_OFFSET_INT=$((RP_OFFSET_INT))
    WP_OFFSET_INT=$((WP_OFFSET_INT))
    BASE=$((base_addr))
    SIZE=$((buffer_size))
    
    echo "$core_name RP偏移: $(printf "0x%X" $RP_OFFSET_INT) int"
    echo "$core_name WP偏移: $(printf "0x%X" $WP_OFFSET_INT) int"
    
    # 关键修正：将int偏移量转换为字节偏移量
    RP_OFFSET_BYTES=$((RP_OFFSET_INT * 4))
    WP_OFFSET_BYTES=$((WP_OFFSET_INT * 4))
    
    echo "$core_name RP字节偏移: $(printf "0x%X" $RP_OFFSET_BYTES) 字节"
    echo "$core_name WP字节偏移: $(printf "0x%X" $WP_OFFSET_BYTES) 字节"
    
    # 计算实际物理地址
    RP_PHYSICAL=$((BASE + RP_OFFSET_BYTES))
    WP_PHYSICAL=$((BASE + WP_OFFSET_BYTES))
    
    echo "$core_name 实际读地址: $(printf "0x%08X" $RP_PHYSICAL)"
    echo "$core_name 实际写地址: $(printf "0x%08X" $WP_PHYSICAL)"
    echo ""
    
    # 清空输出文件
    : > "$output_file"
    
    # 计算需要读取的数据量（处理环形缓冲区）
    if [ $WP_OFFSET_INT -eq $RP_OFFSET_INT ]; then
        echo "$core_name 状态: 缓冲区为空"
        echo "无需读取数据"
        return 0
        
    elif [ $WP_OFFSET_INT -gt $RP_OFFSET_INT ]; then
        # 情况1: WP > RP，正常连续读取
        DATA_SIZE_INT=$((WP_OFFSET_INT - RP_OFFSET_INT))
        DATA_SIZE_BYTES=$((DATA_SIZE_INT * 4))
        
        echo "$core_name 数据布局: 连续区块"
        echo "$core_name 数据大小: $DATA_SIZE_INT int = $DATA_SIZE_BYTES 字节"
        
        if ! read_data_block "$core_name" $BASE $RP_OFFSET_BYTES $DATA_SIZE_BYTES "$output_file"; then
            return 1
        fi
        
    else
        # 情况2: WP < RP，需要处理缓冲区回绕
        FIRST_CHUNK_INT=$((SIZE / 4 - RP_OFFSET_INT))  # 从RP到缓冲区末尾的int数量
        SECOND_CHUNK_INT=$WP_OFFSET_INT                # 从缓冲区开始到WP的int数量
        
        FIRST_CHUNK_BYTES=$((FIRST_CHUNK_INT * 4))
        SECOND_CHUNK_BYTES=$((SECOND_CHUNK_INT * 4))
        TOTAL_BYTES=$((FIRST_CHUNK_BYTES + SECOND_CHUNK_BYTES))
        
        echo "$core_name 数据布局: 环形回绕"
        echo "$core_name 第一段: $FIRST_CHUNK_INT int = $FIRST_CHUNK_BYTES 字节"
        echo "$core_name 第二段: $SECOND_CHUNK_INT int = $SECOND_CHUNK_BYTES 字节"
        echo "$core_name 总大小: $TOTAL_BYTES 字节"
        echo ""
        
        # 读取第一段（从RP到缓冲区末尾）
        if [ $FIRST_CHUNK_BYTES -gt 0 ]; then
            echo "$core_name 读取第一段..."
            if ! read_data_block "$core_name" $BASE $RP_OFFSET_BYTES $FIRST_CHUNK_BYTES "$output_file"; then
                return 1
            fi
        fi
        
        # 读取第二段（从缓冲区开始到WP）
        if [ $SECOND_CHUNK_BYTES -gt 0 ]; then
            echo "$core_name 读取第二段..."
            if ! read_data_block "$core_name" $BASE 0 $SECOND_CHUNK_BYTES "$output_file"; then
                return 1
            fi
        fi
    fi
    
    # 验证结果
    local actual_size=$(wc -c < "$output_file" 2>/dev/null || echo "0")
    local expected_bytes=0
    
    if [ $WP_OFFSET_INT -ge $RP_OFFSET_INT ]; then
        expected_bytes=$(( (WP_OFFSET_INT - RP_OFFSET_INT) * 4 ))
    else
        expected_bytes=$(( (SIZE - RP_OFFSET_BYTES) + WP_OFFSET_BYTES ))
    fi
    
    echo ""
    echo "$core_name 读取完成!"
    echo "输出文件: $output_file"
    echo "预期大小: $expected_bytes 字节"
    echo "实际大小: $actual_size 字节"
    
    if [ $expected_bytes -eq $actual_size ]; then
        echo "状态: ✓ 验证成功"
    else
        echo "状态: ✗ 大小不匹配"
        return 1
    fi
    
    return 0
}

# =============================================
# 函数：显示使用说明
# =============================================
usage() {
    echo "共享缓冲区数据导出工具"
    echo "========================"
    echo "用法: $0 [0|1|all|check|help]"
    echo ""
    echo "参数:"
    echo "  0       导出Core0缓冲区数据"
    echo "  1       导出Core1缓冲区数据" 
    echo "  all     导出所有核心数据（默认）"
    echo "  check   只检查指针状态"
    echo "  help    显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  DEBUG=1 启用调试输出"
    echo ""
    echo "示例:"
    echo "  $0 0        # 只导出Core0数据"
    echo "  $0 all      # 导出所有数据"
    echo "  DEBUG=1 $0 1 # 调试模式导出Core1数据"
}

# =============================================
# 函数：检查指针状态
# =============================================
check_pointers() {
    echo "共享缓冲区指针状态检查"
    echo "========================"
    
    # Core0指针检查
    echo "Core0 状态:"
    RP0=$(safe_devmem_read $CORE0_RP_ADDR 32)
    WP0=$(safe_devmem_read $CORE0_WP_ADDR 32)
    RP0=$((RP0))
    WP0=$((WP0))
    
    echo "  RP: $(printf "0x%X" $RP0) int ($(printf "0x%X" $((RP0 * 4))) 字节)"
    echo "  WP: $(printf "0x%X" $WP0) int ($(printf "0x%X" $((WP0 * 4))) 字节)"
    
    if [ $WP0 -gt $RP0 ]; then
        echo "  数据量: $((WP0 - RP0)) int ($(( (WP0 - RP0) * 4 )) 字节)"
    elif [ $WP0 -lt $RP0 ]; then
        echo "  数据量: $((8192/4 - RP0 + WP0)) int ($(( (8192 - RP0 * 4 + WP0 * 4) )) 字节) - 环形回绕"
    else
        echo "  数据量: 0 int - 缓冲区空"
    fi
    echo ""
    
    # Core1指针检查
    echo "Core1 状态:"
    RP1=$(safe_devmem_read $CORE1_RP_ADDR 32)
    WP1=$(safe_devmem_read $CORE1_WP_ADDR 32)
    RP1=$((RP1))
    WP1=$((WP1))
    
    echo "  RP: $(printf "0x%X" $RP1) int ($(printf "0x%X" $((RP1 * 4))) 字节)"
    echo "  WP: $(printf "0x%X" $WP1) int ($(printf "0x%X" $((WP1 * 4))) 字节)"
    
    if [ $WP1 -gt $RP1 ]; then
        echo "  数据量: $((WP1 - RP1)) int ($(( (WP1 - RP1) * 4 )) 字节)"
    elif [ $WP1 -lt $RP1 ]; then
        echo "  数据量: $((8192/4 - RP1 + WP1)) int ($(( (8192 - RP1 * 4 + WP1 * 4) )) 字节) - 环形回绕"
    else
        echo "  数据量: 0 int - 缓冲区空"
    fi
}

# =============================================
# 主程序
# =============================================
main() {
    local target=${1:-"all"}
    
    echo "共享缓冲区数据导出工具"
    echo "开始时间: $(date)"
    echo ""
    
    # 检查环境
    if ! check_environment; then
        echo "请使用sudo权限运行此脚本"
        exit 1
    fi
    
    case $target in
        "0"|"core0")
            read_shared_buffer "Core0" $CORE0_BASE_ADDR $CORE0_BUFFER_SIZE \
                               $CORE0_RP_ADDR $CORE0_WP_ADDR $CORE0_OUTPUT_FILE
            ;;
        "1"|"core1")
            read_shared_buffer "Core1" $CORE1_BASE_ADDR $CORE1_BUFFER_SIZE \
                               $CORE1_RP_ADDR $CORE1_WP_ADDR $CORE1_OUTPUT_FILE
            ;;
        "all")
            read_shared_buffer "Core0" $CORE0_BASE_ADDR $CORE0_BUFFER_SIZE \
                               $CORE0_RP_ADDR $CORE0_WP_ADDR $CORE0_OUTPUT_FILE
            read_shared_buffer "Core1" $CORE1_BASE_ADDR $CORE1_BUFFER_SIZE \
                               $CORE1_RP_ADDR $CORE1_WP_ADDR $CORE1_OUTPUT_FILE
            ;;
        "check")
            check_pointers
            exit 0
            ;;
        "help"|"-h"|"--help")
            usage
            exit 0
            ;;
        *)
            echo "错误: 未知参数 '$target'"
            usage
            exit 1
            ;;
    esac
    
    echo ""
    echo "操作完成! 结束时间: $(date)"
}

# =============================================
# 脚本入口点
# =============================================
if [ $# -gt 0 ]; then
    main "$1"
else
    main "all"
fi
