set_project("ch32v307_project")
set_version("1.0.0")
set_policy("build.intermediate_directory", false)

-- ==========================================
-- 1. 工具链配置
-- ==========================================
toolchain("riscv_clang")
set_kind("standalone")
set_toolset("cc", "clang")
set_toolset("cxx", "clang++")
set_toolset("as", "clang")
set_toolset("ld", "clang++")

toolchain_end()
set_toolchains("riscv_clang")



-- ==========================================
-- 2. 自动化依赖构建任务
-- ==========================================
task("setup_deps")
on_run(function()
  local work_dir = os.projectdir()

  -- 定义产物路径
  local crt_lib_final = path.absolute(path.join(work_dir, "lib/out/compiler-rt/lib/libclang_rt.builtins-riscv32.a"))
  local picolibc_lib_final = path.absolute(path.join(work_dir, "lib/out/picolibc/lib/libc.a"))

  -- 【关键修复】：第一步就检查终点。如果库文件都在，直接 return，不浪费任何时间去下载或检查源码。
  if os.exists(crt_lib_final) and os.exists(picolibc_lib_final) then
    return
  end

  -- 如果代码运行到这里，说明需要构建，此时再定义各种源码路径
  local llvm_version = "21.1.2"
  local lib_src_dir = path.join(work_dir, "lib/src")
  local lib_out_dir = path.join(work_dir, "lib/out")
  local build_temp = path.join(work_dir, "build/deps")
  local compiler_rt_src = path.join(lib_src_dir, "compiler-rt")
  local llvm_src = path.join(lib_src_dir, "llvm")
  local picolibc_src = path.join(lib_src_dir, "picolibc")

  os.mkdir(lib_src_dir)
  os.mkdir(lib_out_dir)
  os.mkdir(build_temp)

  -- [D] 构建 Compiler-RT
  if not os.exists(crt_lib_final) then
    -- 仅在缺失库文件时，才去检查并下载/解压 LLVM 源码
    for _, name in ipairs({ "llvm", "compiler-rt" }) do
      local dir = (name == "llvm") and llvm_src or compiler_rt_src
      if not os.exists(dir) then
        local filename = name .. "-" .. llvm_version .. ".src.tar.xz"
        local filepath = path.join(lib_src_dir, filename)
        if not os.exists(filepath) then
          print("[Download] Fetching " .. filename .. " (Large file, please wait)...")
          os.execv("curl",
            { "-L", "-o", filepath, "https://github.com/llvm/llvm-project/releases/download/llvmorg-" ..
            llvm_version .. "/" .. filename })
        end
        print("[Extract] Unpacking " .. filename .. "...")
        os.mkdir(dir)
        os.execv("tar", { "-xf", filepath, "-C", dir, "--strip-components=1" })
      end
    end

    print("[Build] Compiler-RT...")
    local custom_mod_dir = path.join(build_temp, "custom_cmake")
    os.rm(custom_mod_dir)
    os.mkdir(custom_mod_dir)

    -- 写入 CMake 修复脚本
    io.writefile(path.join(custom_mod_dir, "GetClangResourceDir.cmake"), [[
function(get_clang_resource_dir out_var prefix)
  execute_process(COMMAND "${CMAKE_C_COMPILER}" -print-resource-dir OUTPUT_VARIABLE RES OUTPUT_STRIP_TRAILING_WHITESPACE)
  set(${out_var} "${RES}" PARENT_SCOPE)
endfunction()
]])
    io.writefile(path.join(custom_mod_dir, "ExtendPath.cmake"), [[
function(extend_path v n p)
  if(IS_ABSOLUTE "${p}")
    set(${v} "${p}" PARENT_SCOPE)
  else()
    set(${v} "${n}/${p}" PARENT_SCOPE)
  endif()
endfunction()
]])
    io.writefile(path.join(custom_mod_dir, "SetPlatformToolchainTools.cmake"), "\n")
    io.writefile(path.join(custom_mod_dir, "HandleCompilerRT.cmake"), "\n")

    local crt_build_dir = path.join(build_temp, "compiler-rt-build")
    os.rm(crt_build_dir)
    os.mkdir(crt_build_dir)

    local llvm_ar = os.iorun("which llvm-ar"):trim()
    local clang_res = os.iorun("clang -print-resource-dir"):trim()
    local common_flags =
        "-target riscv32-unknown-elf -march=rv32imafc_xwchc -mabi=ilp32f -msmall-data-limit=8 -Os -nostdinc -isystem " ..
        clang_res .. "/include"

    os.execv("cmake", {
      "-G", "Ninja", "-S", path.join(compiler_rt_src, "lib/builtins"), "-B", crt_build_dir,
      "-DCMAKE_MODULE_PATH=" .. custom_mod_dir .. ";" .. path.join(llvm_src, "cmake/modules"),
      "-DCMAKE_C_COMPILER=clang", "-DCMAKE_ASM_COMPILER=clang", "-DCMAKE_AR=" .. llvm_ar,
      "-DCMAKE_SYSTEM_NAME=Generic", "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
      "-DCMAKE_C_FLAGS=" .. common_flags, "-DCMAKE_ASM_FLAGS=" .. common_flags,
      "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON", "-DCOMPILER_RT_BAREMETAL_BUILD=ON",
      "-DCOMPILER_RT_OS_DIR=.", "-DCOMPILER_RT_BUILD_BUILTINS=ON", "-DCOMPILER_RT_BUILD_CRT=OFF",
      "-DCOMPILER_RT_BUILD_XRAY=OFF", "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF",
      "-DCOMPILER_RT_BUILD_SANITIZERS=OFF", "-DCOMPILER_RT_BUILD_PROFILE=OFF"
    , "-DCMAKE_C_COMPILER_TARGET=riscv32-unknown-elf",
      "-DCMAKE_ASM_COMPILER_TARGET=riscv32-unknown-elf",


    })
    os.execv("ninja", { "-C", crt_build_dir })

    -- 拷贝产物，防止 ninja install 权限报错
    os.mkdir(path.directory(crt_lib_final))
    os.cp(path.join(crt_build_dir, "lib/libclang_rt.builtins-riscv32.a"), crt_lib_final)
    print("[Success] Compiler-RT deployed to: " .. crt_lib_final)
  end

  -- [E] 构建 Picolibc
  if not os.exists(picolibc_lib_final) then
    if not os.exists(picolibc_src) then
      print("[Git] Cloning Picolibc...")
      os.execv("git", { "clone", "--depth=1", "https://github.com/picolibc/picolibc.git", picolibc_src })
    end

    print("[Build] Picolibc...")
    local pb_build_dir = path.join(build_temp, "picolibc-build")
    os.rm(pb_build_dir)
    local picolibc_install_dir = path.join(work_dir, "lib/out/picolibc")

    local cross_file = path.join(build_temp, "cross.txt")
    io.writefile(cross_file, string.format([[
[binaries]
c = 'clang'
ar = 'llvm-ar'
ld = 'ld.lld'
nm = 'llvm-nm'
objcopy = 'llvm-objcopy'
[built-in options]
c_args = ['-target', 'riscv32-unknown-elf', '-march=rv32imafc_xwchc', '-mabi=ilp32f', '-msmall-data-limit=8', '-Os', '-ffreestanding', '-fno-builtin']
c_link_args = ['-target', 'riscv32-unknown-elf', '-march=rv32imafc_xwchc', '-mabi=ilp32f', '-fuse-ld=lld', '-nostdlib', '-L%s', '-lclang_rt.builtins-riscv32']
[host_machine]
system = 'none'
cpu_family = 'riscv32'
cpu = 'riscv32'
endian = 'little'
]], path.directory(crt_lib_final)))

    os.execv("meson", {
      "setup", pb_build_dir, picolibc_src, "--cross-file", cross_file,
      "--prefix", picolibc_install_dir,
      "-Dmultilib=false", "-Dpicocrt=true", "-Dtests=false", "-Dsemihost=true", "-Dspecsdir=none"
    })
    os.execv("ninja", { "-C", pb_build_dir, "install" })
  end
end)

-- ==========================================
-- 3. 目标配置 (精简优化)
-- ==========================================
target("example")
set_kind("binary")
set_filename("example.elf")
add_files("src/*.c", { rules = "c" })
add_files("src/*.cpp", { rules = "cxx" })



before_build(function(target)
  import("core.project.task").run("setup_deps")
end)

if os.isdir("vendor") then
  add_files("vendor/**/*.c") -- 递归匹配所有子目录
  add_files("vendor/**/*.S")
  -- add_files("vendor/**.c")
  -- add_files("vendor/**.S")
  add_includedirs("vendor/Peripheral/inc", "vendor/Core", "vendor/Debug", "vendor/User")
end

local sysroot = path.absolute("lib/out/picolibc")
local crt_lib_dir = path.absolute("lib/out/compiler-rt/lib")
--
local common_flags = {
  "-target", "riscv32-unknown-elf",
  "-march=rv32imafc_xwchc",
  "-mabi=ilp32f",
  "-msmall-data-limit=8"

  ,
  "-march=rv32imafc_xwchc",
  "-mabi=ilp32f",
  "-msmall-data-limit=8",
  "-mno-save-restore",
  "-Os",
  "-fmessage-length=0",
  "-fsigned-char",
  "-ffunction-sections",
  "-ffreestanding",
  "-fdata-sections",
  "-Wunused",
  "-Wuninitialized",
  "-g",
  "-fno-builtin",
  "-nodefaultlibs",
  "-Wno-unused-command-line-argument",
  "--sysroot=" .. sysroot,
  -- "-nostdinc",
}
--add_cflags("-x c-header", "vendor/Ch32v30x/ch32v30x.h")
add_cxflags("-include ch32v30x.h")


add_cxflags(common_flags, { force = true })
add_cxflags("--sysroot=" .. sysroot,
  "-Os",
  "-ffunction-sections",
  "-fdata-sections",
  "-fno-builtin",
  { force = true }
)

add_asflags(common_flags, { force = true })

add_ldflags(common_flags, { force = true })
add_ldflags("-fuse-ld=lld", "-nostdlib", "-Wl,--gc-sections", "-Wl,--icf=all", "--sysroot=" .. sysroot,
  "-L" .. crt_lib_dir, "-lc", "-lm", "-lclang_rt.builtins-riscv32", { force = true })

if os.exists("vendor/Ld/Link.ld") then
  add_ldflags("-T" .. path.absolute("vendor/Ld/Link.ld"), { force = true })
end

after_build(function(target)
  local elf = target:targetfile()
  local bin = elf:gsub(".elf", ".bin")
  --os.execv("llvm-objcopy", { "-O", "binary", elf, bin })

  -- 只导出 .text 和 .data 段
  os.execv("llvm-objcopy", {
    "-O", "binary",
    "-R", ".stack",
    elf,
    bin
  })

  --llvm-objcopy -O binary -R .stack example.elf example.bin
  --os.execv("llvm-objcopy", { "-O", "binary", elf, bin })
  print("****************************************")
  os.execv("llvm-size", { elf })
  print("****************************************")
end)
