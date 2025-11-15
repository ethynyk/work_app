#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <arpa/inet.h>

// 常量定义
#define MD5SUM_LEN 16
#define LIB_MAX_NAME_LEN 64
#define FUNC_MAX_NAME_LEN 64

// API ID 定义
typedef enum {
    API_ID_A53LITE_LOAD_LIB = 0x90000001,
    API_ID_A53LITE_GET_FUNC = 0x90000002,
    API_ID_A53LITE_LAUNCH_FUNC = 0x90000003,
    API_ID_A53LITE_UNLOAD_LIB = 0x90000004
} API_ID;

// API 头部结构体
typedef struct __attribute__((packed)) {
    uint32_t api_id;
    uint32_t api_size;   // payload大小，单位是4字节的字
    uint64_t api_handle;
    uint32_t api_seq;
    uint32_t duration;
    uint32_t result;
} API_HEADER;

// LOAD/UNLOAD LIB 结构体
typedef struct __attribute__((packed)) {
    uint64_t library_path;
    uint64_t library_addr;
    uint32_t size;
    uint8_t library_name[LIB_MAX_NAME_LEN];
    unsigned char md5[MD5SUM_LEN];
    int32_t cur_rec;
} bm_api_cpu_load_library_internal_t;

// GET_FUNC 结构体
typedef struct __attribute__((packed)) {
    int32_t core_id;
    int32_t f_id;
    unsigned char md5[MD5SUM_LEN];
    unsigned char func_name[FUNC_MAX_NAME_LEN];
} bm1688_get_func_internal_t;

// LAUNCH_FUNC 结构体
typedef struct __attribute__((packed)) {
    int32_t f_id;
    uint32_t size;  // 参数大小，单位是字节
    uint8_t param[4096];
} bm1688_launch_func_internal_t;

// 函数声明
const char* api_id_to_string(uint32_t api_id);
void print_hex(const char* label, const unsigned char* data, size_t len);
void print_string(const char* label, const unsigned char* data, size_t max_len);
void parse_api_header(const API_HEADER* header);
void parse_load_lib_payload(const uint8_t* data, uint32_t payload_bytes);
void parse_get_func_payload(const uint8_t* data, uint32_t payload_bytes);
void parse_launch_func_payload(const uint8_t* data, uint32_t payload_bytes);
void parse_unload_lib_payload(const uint8_t* data, uint32_t payload_bytes);
uint32_t read_uint32(const uint8_t* data);

// API ID 转字符串
const char* api_id_to_string(uint32_t api_id) {
    switch (api_id) {
        case API_ID_A53LITE_LOAD_LIB: return "A53LITE_LOAD_LIB";
        case API_ID_A53LITE_GET_FUNC: return "A53LITE_GET_FUNC";
        case API_ID_A53LITE_LAUNCH_FUNC: return "A53LITE_LAUNCH_FUNC";
        case API_ID_A53LITE_UNLOAD_LIB: return "A53LITE_UNLOAD_LIB";
        default: return "UNKNOWN";
    }
}

// 打印十六进制数据
void print_hex(const char* label, const unsigned char* data, size_t len) {
    printf("  %s: ", label);
    for (size_t i = 0; i < len && i < 16; i++) {
        printf("%02X", data[i]);
    }
    if (len > 16) printf("...");
    printf(" (%zu bytes)\n", len);
}

// 打印字符串（处理非终止字符串）
void print_string(const char* label, const unsigned char* data, size_t max_len) {
    printf("  %s: \"", label);
    size_t len = 0;
    while (len < max_len && data[len] != 0) {
        if (data[len] >= 32 && data[len] < 127) {
            printf("%c", data[len]);
        } else {
            printf("\\x%02X", data[len]);
        }
        len++;
    }
    printf("\"\n");
}

// 读取32位整数（处理字节序）
uint32_t read_uint32(const uint8_t* data) {
    uint32_t value;
    memcpy(&value, data, sizeof(uint32_t));
    return value;
}

// 解析API头部
void parse_api_header(const API_HEADER* header) {
    printf("API头部信息:\n");
    printf("  API_ID: 0x%08X (%s)\n", header->api_id, api_id_to_string(header->api_id));
    printf("  API大小: %u words = %u bytes\n", header->api_size, header->api_size * 4);
    printf("  API句柄: 0x%016lX\n", (unsigned long)header->api_handle);
    printf("  API序列号: %u\n", header->api_seq);
    printf("  持续时间: %u\n", header->duration);
    printf("  结果: %u\n", header->result);
}

// 解析LOAD_LIB payload
void parse_load_lib_payload(const uint8_t* data, uint32_t payload_bytes) {
    printf(">>> LOAD_LIB Payload解析:\n");
    
    if (payload_bytes < sizeof(bm_api_cpu_load_library_internal_t)) {
        printf("  警告: payload大小不足，期望 %zu 字节，实际 %u 字节\n", 
               sizeof(bm_api_cpu_load_library_internal_t), payload_bytes);
        
        // 尝试解析尽可能多的数据
        if (payload_bytes >= sizeof(uint64_t) * 2 + sizeof(uint32_t)) {
            uint64_t library_path, library_addr;
            uint32_t size;
            memcpy(&library_path, data, sizeof(uint64_t));
            memcpy(&library_addr, data + sizeof(uint64_t), sizeof(uint64_t));
            memcpy(&size, data + sizeof(uint64_t) * 2, sizeof(uint32_t));
            
            printf("  库路径指针: 0x%016lX\n", (unsigned long)library_path);
            printf("  库地址指针: 0x%016lX\n", (unsigned long)library_addr);
            printf("  大小: %u\n", size);
        }
        return;
    }
    
    bm_api_cpu_load_library_internal_t* payload = (bm_api_cpu_load_library_internal_t*)data;
    
    printf("  库路径指针: 0x%016lX\n", (unsigned long)payload->library_path);
    printf("  库地址指针: 0x%016lX\n", (unsigned long)payload->library_addr);
    printf("  大小: %u\n", payload->size);
    print_string("库名称", payload->library_name, LIB_MAX_NAME_LEN);
    print_hex("MD5", payload->md5, MD5SUM_LEN);
    printf("  当前记录: %d\n", payload->cur_rec);
}

// 解析GET_FUNC payload
void parse_get_func_payload(const uint8_t* data, uint32_t payload_bytes) {
    printf(">>> GET_FUNC Payload解析:\n");
    
    if (payload_bytes < sizeof(bm1688_get_func_internal_t)) {
        printf("  警告: payload大小不足，期望 %zu 字节，实际 %u 字节\n", 
               sizeof(bm1688_get_func_internal_t), payload_bytes);
        return;
    }
    
    bm1688_get_func_internal_t* payload = (bm1688_get_func_internal_t*)data;
    
    printf("  核心ID: %d\n", payload->core_id);
    printf("  函数ID: %d\n", payload->f_id);
    print_hex("MD5", payload->md5, MD5SUM_LEN);
    print_string("函数名称", payload->func_name, FUNC_MAX_NAME_LEN);
}

// 解析LAUNCH_FUNC payload
void parse_launch_func_payload(const uint8_t* data, uint32_t payload_bytes) {
    printf(">>> LAUNCH_FUNC Payload解析:\n");
    
    // 首先读取f_id和size字段
    if (payload_bytes < sizeof(int32_t) + sizeof(uint32_t)) {
        printf("  错误: payload大小不足以读取基本字段\n");
        printf("  需要至少 %zu 字节，实际 %u 字节\n", 
               sizeof(int32_t) + sizeof(uint32_t), payload_bytes);
        return;
    }
    
    int32_t f_id;
    uint32_t param_size;
    memcpy(&f_id, data, sizeof(int32_t));
    memcpy(&param_size, data + sizeof(int32_t), sizeof(uint32_t));
    
    printf("  函数ID: %d\n", f_id);
    printf("  参数大小: %u 字节\n", param_size);
    
    // 计算可用的参数数据大小
    size_t param_offset = sizeof(int32_t) + sizeof(uint32_t);
    size_t available_param_bytes = (payload_bytes > param_offset) ? (payload_bytes - param_offset) : 0;
    
    printf("  可用参数数据: %zu 字节\n", available_param_bytes);
    
    if (available_param_bytes > 0) {
        size_t display_size = (available_param_bytes < 64) ? available_param_bytes : 64;
        print_hex("参数预览", data + param_offset, display_size);
        
        if (param_size > available_param_bytes) {
            printf("  警告: 声明的参数大小(%u)大于实际可用数据(%zu)\n", param_size, available_param_bytes);
        }
    }
}

// 解析UNLOAD_LIB payload（与LOAD_LIB使用相同结构）
void parse_unload_lib_payload(const uint8_t* data, uint32_t payload_bytes) {
    parse_load_lib_payload(data, payload_bytes);
}

// 主解析函数
void parse_binary_file(const char* filename) {
    FILE* file = fopen(filename, "rb");
    if (file == NULL) {
        perror("打开文件失败");
        return;
    }
    
    // 获取文件大小
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    printf("开始解析文件: %s\n", filename);
    printf("文件大小: %ld 字节\n", file_size);
    printf("========================================\n\n");
    
    size_t message_count = 0;
    size_t total_bytes_processed = 0;
    
    while (total_bytes_processed < file_size) {
        message_count++;
        printf("=== 消息 #%zu (偏移: 0x%08lX) ===\n", message_count, total_bytes_processed);
        
        // 读取API头部
        API_HEADER header;
        size_t header_read = fread(&header, 1, sizeof(API_HEADER), file);
        
        if (header_read != sizeof(API_HEADER)) {
            printf("❌ 读取API头部失败! 需要 %zu 字节，实际读取 %zu 字节\n", 
                   sizeof(API_HEADER), header_read);
            break;
        }
        
        // 解析API头部
        parse_api_header(&header);
        
        // 计算payload字节大小（api_size的单位是4字节的字）
        uint32_t payload_bytes = header.api_size * 4;
        
        // 读取payload数据
        if (payload_bytes > 0) {
            uint8_t* payload = (uint8_t*)malloc(payload_bytes);
            if (payload == NULL) {
                printf("❌ 分配payload内存失败\n");
                break;
            }
            
            size_t payload_read = fread(payload, 1, payload_bytes, file);
            if (payload_read != payload_bytes) {
                printf("⚠️  payload读取不完整! 预期 %u 字节，实际 %zu 字节\n", 
                       payload_bytes, payload_read);
                payload_bytes = payload_read; // 使用实际读取的大小
            }
            
            // 根据API_ID调用相应的解析函数
            switch (header.api_id) {
                case API_ID_A53LITE_LOAD_LIB:
                    parse_load_lib_payload(payload, payload_bytes);
                    break;
                case API_ID_A53LITE_GET_FUNC:
                    parse_get_func_payload(payload, payload_bytes);
                    break;
                case API_ID_A53LITE_LAUNCH_FUNC:
                    parse_launch_func_payload(payload, payload_bytes);
                    break;
                case API_ID_A53LITE_UNLOAD_LIB:
                    parse_unload_lib_payload(payload, payload_bytes);
                    break;
                default:
                    printf(">>> 未知API类型\n");
                    print_hex("原始Payload数据", payload, (payload_bytes < 256) ? payload_bytes : 256);
                    break;
            }
            
            free(payload);
        } else {
            printf(">>> 无Payload数据\n");
        }
        
        total_bytes_processed += sizeof(API_HEADER) + payload_bytes;
        printf("当前已处理: %zu 字节\n\n", total_bytes_processed);
    }
    
    printf("========================================\n");
    printf("解析完成! 总共处理了 %zu 条消息\n", message_count);
    printf("总共处理字节: %zu/%ld (%.1f%%)\n", 
           total_bytes_processed, file_size, 
           (double)total_bytes_processed / file_size * 100);
    
    fclose(file);
}

int main(int argc, char* argv[]) {
    if (argc != 2) {
        printf("用法: %s <二进制文件名>\n", argv[0]);
        printf("示例: %s /data/dump_core0.bin\n", argv[0]);
        return 1;
    }
    
    parse_binary_file(argv[1]);
    return 0;
}
