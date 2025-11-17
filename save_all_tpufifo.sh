#!/bin/bash

# Core0 配置（单位：int）
CORE0_BASE_ADDR=0x2580C000
CORE0_BUFFER_SIZE_INT=0x2000    # 缓冲区大小（以int为单位）
CORE0_RP_ADDR=0x28100084
CORE0_WP_ADDR=0x28100080

# Core1 相对于 Core0 的偏移量
CORE1_POINTER_OFFSET_INT=14      # 14个int（读写指针寄存器偏移）
CORE1_BASE_OFFSET=0x10000        # Core1基地址在Core0基础上偏移0x10000

# 计算Core1的配置（关键修正！）
CORE1_BASE_ADDR=$(printf "0x%X" $((CORE0_BASE_ADDR + CORE1_BASE_OFFSET)))
CORE1_BUFFER_SIZE_INT=0x2000     # 与Core0大小相同
CORE1_RP_ADDR=$(printf "0x%X" $((CORE0_RP_ADDR + CORE1_POINTER_OFFSET_INT * 4)))
CORE1_WP_ADDR=$(printf "0x%X" $((CORE0_WP_ADDR + CORE1_POINTER_OFFSET_INT * 4)))

# 输出文件
OUTPUT_PREFIX="shared_buffer"
CORE0_OUTPUT_FILE="${OUTPUT_PREFIX}_core0.bin"
CORE1_OUTPUT_FILE="${OUTPUT_PREFIX}_core1.bin"

echo "共享缓冲区数据导出脚本（最终修正版）"
echo "=========================================="
echo "Core1基地址计算修正：Core0_BASE + 0x10000"
echo ""

# 显示配置信息
echo "Core0配置:"
echo "  基地址: $(printf "0x%08X" $CORE0_BASE_ADDR)"
echo "  缓冲区大小: $(printf "0x%X" $CORE0_BUFFER_SIZE_INT) int"
echo "  读写指针: RP=$(printf "0x%08X" $CORE0_RP_ADDR), WP=$(printf "0x%08X" $CORE0_WP_ADDR)"
echo ""

echo "Core1配置:"
echo "  基地址: $(printf "0x%08X" $CORE1_BASE_ADDR) (Core0 + 0x10000)"
echo "  缓冲区大小: $(printf "0x%X" $CORE1_BUFFER_SIZE_INT) int"
echo "  读写指针: RP=$(printf "0x%08X" $CORE1_RP_ADDR), WP=$(printf "0x%08X" $CORE1_WP_ADDR)"
echo "  指针偏移: 14个int = $(printf "0x%X" $((CORE1_POINTER_OFFSET_INT * 4))) 字节"
echo ""

# 检查工具
if ! command -v busybox > /dev/null 2>&1; then
    echo "错误: 未找到busybox"
    exit 1
fi

# 读取共享缓冲区数据的函数
read_shared_buffer() {
    local core_name=$1
    local base_addr=$2
    local buffer_size_int=$3
    local rp_addr=$4
    local wp_addr=$5
    local output_file=$6
    
    echo ""
    echo "正在读取${core_name}的共享缓冲区数据..."
    echo "=========================================="
    
    # 读取RP和WP值（这些值是以int为单位的偏移量）
    echo "正在读取${core_name}的读指针(RP)和写指针(WP)..."
    RP_OFFSET_INT=$(busybox devmem $rp_addr 32)
    WP_OFFSET_INT=$(busybox devmem $wp_addr 32)
    
    # 转换为十进制
    RP_OFFSET_INT=$((RP_OFFSET_INT))
    WP_OFFSET_INT=$((WP_OFFSET_INT))
    BASE=$((base_addr))
    SIZE_INT=$((buffer_size_int))
    
    echo "${core_name}读指针偏移量: $(printf "0x%X" $RP_OFFSET_INT) int"
    echo "${core_name}写指针偏移量: $(printf "0x%X" $WP_OFFSET_INT) int"
    
    # 关键计算：实际物理地址 = 基地址 + (int偏移量 × 4)
    RP_PHYSICAL=$((BASE + RP_OFFSET_INT * 4))
    WP_PHYSICAL=$((BASE + WP_OFFSET_INT * 4))
    
    echo "${core_name}实际读地址: $(printf "0x%08X" $RP_PHYSICAL) (BASE + RP_OFFSET × 4)"
    echo "${core_name}实际写地址: $(printf "0x%08X" $WP_PHYSICAL) (BASE + WP_OFFSET × 4)"
    echo ""
    
    # 清空输出文件
    : > "$output_file"
    
    # 计算需要读取的数据量（以int为单位）
    if [ $WP_OFFSET_INT -ge $RP_OFFSET_INT ]; then
        # 情况1: WP在RP之后
        DATA_SIZE_INT=$((WP_OFFSET_INT - RP_OFFSET_INT))
        DATA_SIZE_BYTES=$((DATA_SIZE_INT * 4))
        
        echo "${core_name}数据布局: 连续区块 (WP ≥ RP)"
        echo "${core_name}数据大小: $DATA_SIZE_INT int = $DATA_SIZE_BYTES 字节"
        echo "读取范围: 偏移量 $(printf "0x%X" $RP_OFFSET_INT) - $(printf "0x%X" $WP_OFFSET_INT) int"
        echo ""
        
        # 读取数据
        ints_read=0
        current_offset_int=$RP_OFFSET_INT
        
        while [ $ints_read -lt $DATA_SIZE_INT ]; do
            # 计算当前物理地址：BASE + (current_offset_int × 4)
            current_physical_addr=$((BASE + current_offset_int * 4))
            VALUE=$(busybox devmem $current_physical_addr 32)
            
            # 将32位值写入文件（小端序）
            printf "\\x$(printf "%02X" $((VALUE & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 8 & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 16 & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 24 & 0xFF)))" >> "$output_file"
            
            current_offset_int=$((current_offset_int + 1))
            ints_read=$((ints_read + 1))
            
            # 显示进度
            if [ $((ints_read % 64)) -eq 0 ] || [ $ints_read -eq $DATA_SIZE_INT ]; then
                percent=$((ints_read * 100 / DATA_SIZE_INT))
                bytes_read=$((ints_read * 4))
                printf "${core_name}进度: %d/%d int (%d字节, %d%%)\\r" $ints_read $DATA_SIZE_INT $bytes_read $percent
            fi
        done
        
    else
        # 情况2: WP在RP之前，需要处理缓冲区回绕
        FIRST_CHUNK_INT=$((SIZE_INT - RP_OFFSET_INT))
        SECOND_CHUNK_INT=$WP_OFFSET_INT
        TOTAL_INT=$((FIRST_CHUNK_INT + SECOND_CHUNK_INT))
        
        echo "${core_name}数据布局: 环形回绕 (WP < RP)"
        echo "${core_name}第一段大小: $FIRST_CHUNK_INT int (从偏移量 $(printf "0x%X" $RP_OFFSET_INT) 到末尾)"
        echo "${core_name}第二段大小: $SECOND_CHUNK_INT int (从开头到偏移量 $(printf "0x%X" $WP_OFFSET_INT))"
        echo "${core_name}总数据大小: $TOTAL_INT int"
        echo ""
        
        # 读取第一段（从RP到缓冲区末尾）
        echo "读取第一段数据..."
        ints_read=0
        current_offset_int=$RP_OFFSET_INT
        
        while [ $ints_read -lt $FIRST_CHUNK_INT ]; do
            current_physical_addr=$((BASE + current_offset_int * 4))
            VALUE=$(busybox devmem $current_physical_addr 32)
            
            printf "\\x$(printf "%02X" $((VALUE & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 8 & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 16 & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 24 & 0xFF)))" >> "$output_file"
            
            current_offset_int=$((current_offset_int + 1))
            ints_read=$((ints_read + 1))
        done
        echo "第一段读取完成"
        
        # 读取第二段（从缓冲区开始到WP）
        echo "读取第二段数据..."
        ints_read=0
        current_offset_int=0
        
        while [ $ints_read -lt $SECOND_CHUNK_INT ]; do
            current_physical_addr=$((BASE + current_offset_int * 4))
            VALUE=$(busybox devmem $current_physical_addr 32)
            
            printf "\\x$(printf "%02X" $((VALUE & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 8 & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 16 & 0xFF)))" >> "$output_file"
            printf "\\x$(printf "%02X" $((VALUE >> 24 & 0xFF)))" >> "$output_file"
            
            current_offset_int=$((current_offset_int + 1))
            ints_read=$((ints_read + 1))
        done
        echo "第二段读取完成"
    fi
    
    echo ""
    echo "${core_name}数据导出完成!"
    echo "输出文件: $output_file"
    echo "文件大小: $(wc -c < "$output_file") 字节"
    
    # 验证
    expected_bytes=0
    if [ $WP_OFFSET_INT -ge $RP_OFFSET_INT ]; then
        expected_bytes=$(( (WP_OFFSET_INT - RP_OFFSET_INT) * 4 ))
    else
        expected_bytes=$(( (SIZE_INT - RP_OFFSET_INT + WP_OFFSET_INT) * 4 ))
    fi
    
    actual_bytes=$(wc -c < "$output_file")
    echo "预期大小: $expected_bytes 字节"
    echo "实际大小: $actual_bytes 字节"
    
    if [ $expected_bytes -eq $actual_bytes ]; then
        echo "状态: ✓ 数据大小验证成功"
    else
        echo "状态: ✗ 数据大小不匹配"
    fi
    echo ""
}

# 主程序
main() {
    local target=${1:-"all"}
    
    case $target in
        "core0")
            read_shared_buffer "Core0" $CORE0_BASE_ADDR $CORE0_BUFFER_SIZE_INT \
                               $CORE0_RP_ADDR $CORE0_WP_ADDR $CORE0_OUTPUT_FILE
            ;;
        "core1")
            read_shared_buffer "Core1" $CORE1_BASE_ADDR $CORE1_BUFFER_SIZE_INT \
                               $CORE1_RP_ADDR $CORE1_WP_ADDR $CORE1_OUTPUT_FILE
            ;;
        "all")
            read_shared_buffer "Core0" $CORE0_BASE_ADDR $CORE0_BUFFER_SIZE_INT \
                               $CORE0_RP_ADDR $CORE0_WP_ADDR $CORE0_OUTPUT_FILE
            read_shared_buffer "Core1" $CORE1_BASE_ADDR $CORE1_BUFFER_SIZE_INT \
                               $CORE1_RP_ADDR $CORE1_WP_ADDR $CORE1_OUTPUT_FILE
            ;;
        *)
            echo "用法: $0 [core0|core1|all]"
            exit 1
            ;;
    esac
}

# 运行脚本
main "$@"
