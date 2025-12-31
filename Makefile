TARGET_EXEC ?= example.elf
TARGET_BIN ?= example.bin

AS := clang
CC := clang
CXX := clang++

BUILD_DIR ?= ./build
SRC_DIRS ?= ./src ./vendor/Core ./vendor/Debug ./vendor/Peripheral ./vendor/Startup ./vendor/User

SRCS := $(shell find $(SRC_DIRS) -name "*.cpp" -or -name "*.c" -or -name "*.S")
OBJS := $(SRCS:%=$(BUILD_DIR)/%.o)
DEPS := $(OBJS:.o=.d)

INC_DIRS := $(shell find $(SRC_DIRS) -type d)
INC_FLAGS := $(addprefix -I,$(INC_DIRS))

FLAGS ?= -target riscv32-unknown-elf -march=rv32imafc_xwchc -mabi=ilp32f -msmall-data-limit=8 -mno-save-restore -Os -fmessage-length=0 -fsigned-char -ffunction-sections  -ffreestanding -fdata-sections -Wunused -Wuninitialized -g -fno-builtin -fno-pic -fno-plt -fno-pie -no-pie -nodefaultlibs -Wno-unused-command-line-argument --sysroot=./lib/out/picolibc -nostdinc -isystem ./lib/out/picolibc/include -isystem $(shell clang -print-resource-dir)/include -flto -include stddef.h -include stdint.h -include ch32v30x.h
ASFLAGS ?= $(FLAGS) -x assembler $(INC_FLAGS) -MMD -MP
CFLAGS ?=  $(FLAGS) $(INC_FLAGS) -std=gnu23 -MMD -MP
CPPFLAGS ?=  $(FLAGS) $(INC_FLAGS) -std=gnu++23 -MMD -MP -fno-rtti
LDFLAGS ?= $(FLAGS) -fuse-ld=lld -T ./vendor/Ld/Link.ld -nostdlib -nostartfiles -nodefaultlibs -L./lib/out/picolibc/lib -L./lib/out/compiler-rt/lib -Xlinker --gc-sections -Wl,-Map,"$(BUILD_DIR)/CH32V307VCT6.map" -lc -lm -lclang_rt.builtins-riscv32

all: $(BUILD_DIR)/$(TARGET_EXEC) $(BUILD_DIR)/$(TARGET_BIN)

$(BUILD_DIR)/$(TARGET_EXEC): $(OBJS)
	$(CC) $(OBJS) -o $@ $(LDFLAGS)
	@echo "-------------------------------------------------------------------"
	@llvm-size -B $@
	@echo "-------------------------------------------------------------------"

$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	llvm-objcopy -O binary -R .stack $< $@

# assembly
$(BUILD_DIR)/%.S.o: %.S
	$(MKDIR_P) $(dir $@)
	$(CC) $(ASFLAGS) -c $< -o $@

# c source
$(BUILD_DIR)/%.c.o: %.c
	$(MKDIR_P) $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

# c++ source
$(BUILD_DIR)/%.cpp.o: %.cpp
	$(MKDIR_P) $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@


.PHONY: clean

clean:
	$(RM) -r $(BUILD_DIR)

-include $(DEPS)

MKDIR_P ?= mkdir -p
