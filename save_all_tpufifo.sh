#!/bin/bash

# =============================================
# 共享缓冲区配置（所有地址和大小单位均为字节）
# =============================================

# Core0 配置
CORE0_BASE_ADDR=0x2580C000
CORE0_BUFFER_SIZE=0x8000          # 缓冲区大小（字节）0x2000 * 4
CORE0_RP_ADDR=0x28100084          # 读指针寄存器地址
CORE0_WP_ADDR=0x28100080          # 写指针寄存器地址

# Core1 配置（在Core0基础上偏移）
CORE1_BASE_ADDR=0x2581C000        # Core0基地址 + 0x10000
CORE1_BUFFER_SIZE=0x8000          # 与Core0大小相同
CORE1_RP_ADDR=0x281000BC          # Core0读指针地址 + 14 * 4 = 0x38
CORE1_WP_ADDR=0x281000B8          # Core0写指针地址 + 14 * 4 = 0x38

# 输出文件配置
OUTPUT_PREFIX="shared_buffer"
CORE0_OUTPUT_FILE="${OUTPUT_PREFIX}_core0.bin"
CORE1_OUTPUT_FILE="${OUTPUT_PREFIX}_core1.bin"

# 调试模式（0=关闭，1=开启）
DEBUG_MODE=0

# =============================================
# 函数：调试信息输出
# =============================================
debug_echo() {
    if [ $DEBUG_MODE -eq 1 ]; then
        echo "[DEBUG] $1"
    fi
}

# =============================================
# 函数：检查环境和工具
# =============================================
check_environment() {
    echo "检查环境和工具..."
    
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
        echo "错误: 没有读取/dev/mem的权限，请使用sudo运行"
        return 1
    fi
    
    # 检查输出目录权限
    if ! touch "$CORE0_OUTPUT_FILE" 2>/dev/null; then
        echo "错误: 无法创建输出文件，检查目录权限"
        return 1
    fi
    rm -f "$CORE0_OUTPUT_FILE"
    
    echo "环境检查通过"
    return 0
}

# =============================================
# 函数：安全读取内存地址
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
# 函数：读取共享缓冲区数据
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
    echo "开始读取 $core_name 共享缓冲区数据"
    echo "=========================================="
    echo "基地址: $(printf "0x%08X" $base_addr)"
    echo "缓冲区大小: $(printf "0x%X" $buffer_size) 字节"
    echo "读指针地址: $(printf "0x%08X" $rp_addr)"
    echo "写指针地址: $(printf "0x%08X" $wp_addr)"
    echo "输出文件: $output_file"
    echo ""
    
    # 读取读指针和写指针
    echo "正在读取指针寄存器..."
    RP_OFFSET=$(safe_devmem_read $rp_addr 32)
    if [ $? -ne 0 ]; then
        echo "错误: 读取RP指针失败"
        return 1
    fi
    
    WP_OFFSET=$(safe_devmem_read $wp_addr 32)
    if [ $? -ne 0 ]; then
        echo "错误: 读取WP指针失败"
        return 1
    fi
    
    # 转换为十进制
    RP_OFFSET=$((RP_OFFSET))
    WP_OFFSET=$((WP_OFFSET))
    BASE=$((base_addr))
    SIZE=$((buffer_size))
    
    echo "$core_name 读指针偏移: $(printf "0x%X" $RP_OFFSET) 字节"
    echo "$core_name 写指针偏移: $(printf "0x%X" $WP_OFFSET) 字节"
    
    # 验证偏移量有效性
    if [ $RP_OFFSET -ge $SIZE ] || [ $WP_OFFSET -ge $SIZE ]; then
        echo "警告: 指针偏移量可能超出缓冲区范围"
        echo "缓冲区大小: $(printf "0x%X" $SIZE) 字节"
        echo "自动调整指针偏移量..."
        RP_OFFSET=$((RP_OFFSET % SIZE))
        WP_OFFSET=$((WP_OFFSET % SIZE))
        echo "调整后RP偏移: $(printf "0x%X" $RP_OFFSET)"
        echo "调整后WP偏移: $(printf "0x%X" $WP_OFFSET)"
    fi
    
    # 计算实际物理地址
    RP_PHYSICAL=$((BASE + RP_OFFSET))
    WP_PHYSICAL=$((BASE + WP_OFFSET))
    
    echo "$core_name 实际读地址: $(printf "0x%08X" $RP_PHYSICAL)"
    echo "$core_name 实际写地址: $(printf "0x%08X" $WP_PHYSICAL)"
    echo ""
    
    # 清空输出文件
    : > "$output_file"
    
    # 计算需要读取的数据量
    if [ $WP_OFFSET -eq $RP_OFFSET ]; then
        echo "$core_name 状态: 缓冲区为空（RP == WP）"
        echo "无需读取数据"
        return 0
        
    elif [ $WP_OFFSET -gt $RP_OFFSET ]; then
        # 情况1: WP > RP，正常连续读取
        DATA_SIZE=$((WP_OFFSET - RP_OFFSET))
        echo "$core_name 数据布局: 连续区块（WP > RP）"
        echo "$core_name 数据大小: $DATA_SIZE 字节"
        echo "读取范围: 偏移量 $(printf "0x%X" $RP_OFFSET) - $(printf "0x%X" $WP_OFFSET)"
        echo ""
        
        if ! read_continuous_data "$core_name" "$BASE" "$RP_OFFSET" "$DATA_SIZE" "$output_file"; then
            return 1
        fi
        
    else
        # 情况2: WP < RP，环形缓冲区回绕
        FIRST_CHUNK_SIZE=$((SIZE - RP_OFFSET))  # 从RP到缓冲区末尾
        SECOND_CHUNK_SIZE=$WP_OFFSET            # 从缓冲区开始到WP
        TOTAL_SIZE=$((FIRST_CHUNK_SIZE + SECOND_CHUNK_SIZE))
        
        echo "$core_name 数据布局: 环形回绕（WP < RP）"
        echo "$core_name 第一段大小: $FIRST_CHUNK_SIZE 字节（从RP到缓冲区末尾）"
        echo "$core_name 第二段大小: $SECOND_CHUNK_SIZE 字节（从开始到WP）"
        echo "$core_name 总数据大小: $TOTAL_SIZE 字节"
        echo ""
        
        # 读取第一段数据
        if [ $FIRST_CHUNK_SIZE -gt 0 ]; then
            echo "$core_name 读取第一段数据..."
            if ! read_continuous_data "$core_name" "$BASE" "$RP_OFFSET" "$FIRST_CHUNK_SIZE" "$output_file"; then
                return 1
            fi
        fi
        
        # 读取第二段数据
        if [ $SECOND_CHUNK_SIZE -gt 0 ]; then
            echo "$core_name 读取第二段数据..."
            if ! read_continuous_data "$core_name" "$BASE" "0" "$SECOND_CHUNK_SIZE" "$output_file"; then
                return 1
            fi
        fi
    fi
    
    # 验证输出文件
    local actual_size=$(wc -c < "$output_file" 2>/dev/null || echo "0")
    echo ""
    echo "$core_name 数据读取完成!"
    echo "输出文件: $output_file"
    echo "文件大小: $actual_size 字节"
    
    return 0
}

# =============================================
# 函数：读取连续数据块
# =============================================
read_continuous_data() {
    local core_name=$1
    local base_addr=$2
    local start_offset=$3
    local data_size=$4
    local output_file=$5
    
    local bytes_read=0
    local current_offset=$start_offset
    local batch_size=256  # 每批次读取256字节，平衡性能与进度显示
    
    # 计算预期读取的批次数量
    local total_batches=$(( (data_size + batch_size - 1) / batch_size ))
    local current_batch=0
    
    while [ $bytes_read -lt $data_size ]; do
        local remaining=$((data_size - bytes_read))
        local current_batch_size=$((remaining < batch_size ? remaining : batch_size))
        
        # 读取一个批次的数据
        for ((i=0; i<current_batch_size; i++)); do
            local current_addr=$((base_addr + current_offset))
            
            # 读取1字节数据
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
        
        # 显示进度（覆盖上一行）
        printf "\r%s 进度: %d/%d 字节 (%d%%)" "$core_name" $bytes_read $data_size $percent
        
        # 每10%或完成时换行显示详细信息
        if [ $((current_batch % 10)) -eq 0 ] || [ $bytes_read -eq $data_size ]; then
            printf "\n"
            debug_echo "已读取: $bytes_read/$data_size 字节, 当前偏移: $(printf "0x%X" $current_offset)"
        fi
    done
    
    echo ""
    return 0
}

# =============================================
# 函数：显示使用说明
# =============================================
usage() {
    echo "共享缓冲区数据导出脚本"
    echo "========================"
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  core0      只导出Core0的缓冲区数据"
    echo "  core1      只导出Core1的缓冲区数据"
    echo "  all        导出所有核心的缓冲区数据（默认）"
    echo "  check      只检查指针状态，不导出数据"
    echo "  help       显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 core0        # 只导出Core0数据"
    echo "  $0 all          # 导出所有核心数据"
    echo "  $0 check        # 检查指针状态"
    echo ""
}

# =============================================
# 函数：检查指针状态
# =============================================
check_pointers() {
    echo "检查共享缓冲区指针状态..."
    echo "================================"
    
    # Core0指针检查
    echo "Core0 指针状态:"
    RP0=$(safe_devmem_read $CORE0_RP_ADDR 32)
    WP0=$(safe_devmem_read $CORE0_WP_ADDR 32)
    echo "  RP: $(printf "0x%08X" $RP0) (偏移: $(printf "0x%X" $RP0))"
    echo "  WP: $(printf "0x%08X" $WP0) (偏移: $(printf "0x%X" $WP0))"
    
    if [ $WP0 -gt $RP0 ]; then
        echo "  数据量: $((WP0 - RP0)) 字节"
    elif [ $WP0 -lt $RP0 ]; then
        echo "  数据量: $((0x8000 - RP0 + WP0)) 字节（环形回绕）"
    else
        echo "  数据量: 0 字节（缓冲区空）"
    fi
    echo ""
    
    # Core1指针检查
    echo "Core1 指针状态:"
    RP1=$(safe_devmem_read $CORE1_RP_ADDR 32)
    WP1=$(safe_devmem_read $CORE1_WP_ADDR 32)
    echo "  RP: $(printf "0x%08X" $RP1) (偏移: $(printf "0x%X" $RP1))"
    echo "  WP: $(printf "0x%08X" $WP1) (偏移: $(printf "0x%X" $WP1))"
    
    if [ $WP1 -gt $RP1 ]; then
        echo "  数据量: $((WP1 - RP1)) 字节"
    elif [ $WP1 -lt $RP1 ]; then
        echo "  数据量: $((0x8000 - RP1 + WP1)) 字节（环形回绕）"
    else
        echo "  数据量: 0 字节（缓冲区空）"
    fi
    echo ""
}

# =============================================
# 主程序
# =============================================
main() {
    local target=${1:-"all"}
    
    echo "共享缓冲区数据导出工具"
    echo "========================"
    echo "开始时间: $(date)"
    echo ""
    
    # 检查环境
    if ! check_environment; then
        echo "环境检查失败，请解决问题后重试"
        exit 1
    fi
    
    case $target in
        "core0")
            read_shared_buffer "Core0" $CORE0_BASE_ADDR $CORE0_BUFFER_SIZE \
                               $CORE0_RP_ADDR $CORE0_WP_ADDR $CORE0_OUTPUT_FILE
            ;;
        "core1")
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
    echo "操作完成!"
    echo "结束时间: $(date)"
}

# =============================================
# 脚本入口点
# =============================================
if [ $# -gt 0 ]; then
    main "$1"
else
    main "all"
fi
