import os
import subprocess
import shutil
import sys
import urllib.request

# ==========================================
# Configuration
# ==========================================
LLVM_VERSION = "21.1.0"
BASE_URL = (
    f"https://github.com/llvm/llvm-project/releases/download/llvmorg-{LLVM_VERSION}"
)

# Target Architecture Flags (Must match Makefile)
ARCH_FLAGS = [
    "-target",
    "riscv32-unknown-elf",
    "-march=rv32imafc_xwchc",
    "-mabi=ilp32f",
    "-msmall-data-limit=8",
    "-mno-save-restore",
    "-Os",
    "-fmessage-length=0",
    "-fsigned-char",
    "-ffunction-sections",
    "-fdata-sections",
    "-Wunused",
    "-Wuninitialized",
    "-g",
    "-fno-builtin",
    "-nodefaultlibs",
    "-Wno-unused-command-line-argument",
]

# Directories
WORK_DIR = os.path.abspath(".")
LIB_DIR = os.path.join(WORK_DIR, "lib")
LIB_SRC_DIR = os.path.join(LIB_DIR, "src")
LIB_OUT_DIR = os.path.join(LIB_DIR, "out")

PICOLIBC_SRC_DIR = os.path.join(LIB_SRC_DIR, "picolibc")
PICOLIBC_BUILD_DIR = os.path.join(WORK_DIR, "build/picolibc")
PICOLIBC_INSTALL_DIR = os.path.join(LIB_OUT_DIR, "picolibc")

COMPILER_RT_SRC_DIR = os.path.join(LIB_SRC_DIR, "compiler-rt")
COMPILER_RT_BUILD_DIR = os.path.join(WORK_DIR, "build/compiler-rt")
COMPILER_RT_INSTALL_DIR = os.path.join(LIB_OUT_DIR, "compiler-rt")

# Files to download
DOWNLOAD_FILES = [
    f"cmake-{LLVM_VERSION}.src.tar.xz",
    f"compiler-rt-{LLVM_VERSION}.src.tar.xz",
    f"llvm-{LLVM_VERSION}.src.tar.xz",
]


# ==========================================
# Helpers
# ==========================================
def run_cmd(cmd, cwd=None):
    print(f"[Exec] {' '.join(cmd)}")
    subprocess.check_call(cmd, cwd=cwd)


def download_file(url, filename):
    # Download to LIB_SRC_DIR
    filepath = os.path.join(LIB_SRC_DIR, filename)
    if os.path.exists(filepath):
        print(f"[Info] {filepath} exists, skipping.")
        return
    print(f"[Download] {url} -> {filepath} ...")
    try:
        with urllib.request.urlopen(url) as response, open(filepath, "wb") as out_file:
            shutil.copyfileobj(response, out_file)
    except Exception as e:
        print(f"[Error] Download failed: {e}")
        sys.exit(1)


def extract_tar(filename, dest_dir, strip=1):
    # Extract from LIB_SRC_DIR
    filepath = os.path.join(LIB_SRC_DIR, filename)
    if not os.path.exists(dest_dir):
        os.makedirs(dest_dir)
        print(f"[Extract] {filepath} -> {dest_dir}")
        run_cmd(["tar", "-xf", filepath, "-C", dest_dir, f"--strip-components={strip}"])


# ==========================================
# Steps
# ==========================================


def step0_prepare_dirs():
    print("\n=== 0. Prepare Directories ===")
    if not os.path.exists(LIB_SRC_DIR):
        os.makedirs(LIB_SRC_DIR)
    if not os.path.exists(LIB_OUT_DIR):
        os.makedirs(LIB_OUT_DIR)


def step1_prepare_picolibc_src():
    print("\n=== 1. Prepare picolibc Source ===")
    if not os.path.exists(PICOLIBC_SRC_DIR):
        print(f"[Clone] Cloning picolibc to {PICOLIBC_SRC_DIR} ...")
        run_cmd(
            [
                "git",
                "clone",
                "--filter",
                "blob:none",
                "--depth=1",
                "https://github.com/picolibc/picolibc.git",
                PICOLIBC_SRC_DIR,
            ]
        )
    else:
        print(f"[Info] {PICOLIBC_SRC_DIR} exists, skipping clone.")


def step2_prepare_compiler_rt_src():
    print("\n=== 2. Prepare compiler-rt Source ===")
    # Download necessary tarballs
    for f in DOWNLOAD_FILES:
        download_file(f"{BASE_URL}/{f}", f)

    # Extract compiler-rt
    extract_tar(f"compiler-rt-{LLVM_VERSION}.src.tar.xz", COMPILER_RT_SRC_DIR)

    # Extract cmake modules (needed for build)
    # Use a temp dir in build/ for cmake modules to avoid cluttering root
    llvm_cmake_dir = os.path.join(WORK_DIR, "build", "llvm-cmake-modules")
    extract_tar(
        f"cmake-{LLVM_VERSION}.src.tar.xz", os.path.join(llvm_cmake_dir, "cmake")
    )
    extract_tar(f"llvm-{LLVM_VERSION}.src.tar.xz", os.path.join(llvm_cmake_dir, "llvm"))

    # Create missing helper modules for compiler-rt
    crt_modules_dir = os.path.join(COMPILER_RT_SRC_DIR, "cmake", "Modules")
    if not os.path.exists(crt_modules_dir):
        os.makedirs(crt_modules_dir)

    with open(os.path.join(crt_modules_dir, "GetClangResourceDir.cmake"), "w") as f:
        f.write("""
function(get_clang_resource_dir out_var prefix)
  if(DEFINED CLANG_RESOURCE_DIR)
    set(${out_var} "${CLANG_RESOURCE_DIR}" PARENT_SCOPE)
    return()
  endif()
  execute_process(
    COMMAND "${CMAKE_C_COMPILER}" -print-resource-dir
    RESULT_VARIABLE HAD_ERROR
    OUTPUT_VARIABLE RESOURCE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(HAD_ERROR)
    message(FATAL_ERROR "Failed to get clang resource dir")
  endif()
  set(${out_var} "${RESOURCE_DIR}" PARENT_SCOPE)
endfunction()
""")

    with open(os.path.join(crt_modules_dir, "ExtendPath.cmake"), "w") as f:
        f.write("""
function(extend_path out_var base_path path_to_append)
  if(IS_ABSOLUTE "${path_to_append}")
    set(${out_var} "${path_to_append}" PARENT_SCOPE)
  else()
    set(${out_var} "${base_path}/${path_to_append}" PARENT_SCOPE)
  endif()
endfunction()
""")

    # Create dummy SetPlatformToolchainTools.cmake
    with open(
        os.path.join(crt_modules_dir, "SetPlatformToolchainTools.cmake"), "w"
    ) as f:
        f.write("# Dummy file to satisfy dependency\\n")

    # Create dummy HandleCompilerRT.cmake
    with open(os.path.join(crt_modules_dir, "HandleCompilerRT.cmake"), "w") as f:
        f.write("# Dummy file to satisfy dependency\\n")

    return llvm_cmake_dir


def step3_build_compiler_rt(llvm_cmake_dir):
    print("\n=== 3. Build compiler-rt ===")
    if os.path.exists(COMPILER_RT_BUILD_DIR):
        shutil.rmtree(COMPILER_RT_BUILD_DIR)
    os.makedirs(COMPILER_RT_BUILD_DIR)

    clang_res_dir = (
        subprocess.check_output(["clang", "-print-resource-dir"]).decode().strip()
    )

    # compiler-rt builtins should be freestanding and not depend on libc headers
    c_flags = (
        " ".join(ARCH_FLAGS)
        + f" -nostdinc -isystem {clang_res_dir}/include"
    )

    # We need to trick compiler-rt into thinking it's in a monorepo or provide correct paths
    # The error says LLVM_CMAKE_DIR does not exist.
    # We extracted llvm-21.1.0.src.tar.xz to llvm-cmake-modules/llvm
    # The path should be llvm-cmake-modules/llvm/cmake/modules

    cmake_args = [
        "cmake",
        "-G",
        "Ninja",
        f"-S{os.path.join(COMPILER_RT_SRC_DIR, 'lib', 'builtins')}",
        f"-B{COMPILER_RT_BUILD_DIR}",
        f"-DCMAKE_MODULE_PATH={os.path.join(llvm_cmake_dir, 'llvm', 'cmake', 'modules')}",
        f"-DLLVM_CMAKE_DIR={os.path.join(llvm_cmake_dir, 'llvm', 'cmake', 'modules')}",
        f"-DLLVM_MAIN_SRC_DIR={os.path.join(llvm_cmake_dir, 'llvm')}",
        "-DCMAKE_C_COMPILER=clang",
        "-DCMAKE_CXX_COMPILER=clang++",
        "-DCMAKE_ASM_COMPILER=clang",
        "-DCMAKE_AR=/run/current-system/sw/bin/llvm-ar",
        "-DCMAKE_NM=/run/current-system/sw/bin/llvm-nm",
        "-DCMAKE_RANLIB=/run/current-system/sw/bin/llvm-ranlib",
        "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
        "-DCMAKE_C_COMPILER_TARGET=riscv32-unknown-elf",
        "-DCMAKE_ASM_COMPILER_TARGET=riscv32-unknown-elf",
        f"-DCMAKE_C_FLAGS={c_flags}",
        f"-DCMAKE_ASM_FLAGS={c_flags}",
        "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON",
        "-DCOMPILER_RT_BAREMETAL_BUILD=ON",
        "-DCOMPILER_RT_BUILD_BUILTINS=ON",
        "-DCOMPILER_RT_BUILD_SANITIZERS=OFF",
        "-DCOMPILER_RT_BUILD_XRAY=OFF",
        "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF",
        "-DCOMPILER_RT_BUILD_PROFILE=OFF",
        "-DCOMPILER_RT_OS_DIR=.",
        f"-DCMAKE_INSTALL_PREFIX={COMPILER_RT_INSTALL_DIR}",
        f"-DCOMPILER_RT_INSTALL_PATH={COMPILER_RT_INSTALL_DIR}",
    ]

    run_cmd(cmake_args)
    run_cmd(["ninja", "-C", COMPILER_RT_BUILD_DIR, "install"])

    # Locate the built library
    lib_name = "libclang_rt.builtins-riscv32.a"
    possible_paths = [
        os.path.join(COMPILER_RT_INSTALL_DIR, "lib", "linux", lib_name),
        os.path.join(COMPILER_RT_INSTALL_DIR, "lib", lib_name),
    ]

    final_lib = None
    for p in possible_paths:
        if os.path.exists(p):
            final_lib = p
            break

    if not final_lib:
        print("[Error] compiler-rt lib not found!")
        sys.exit(1)

    print(f"[Success] compiler-rt built at {final_lib}")
    return final_lib


def step4_build_picolibc(crt_lib_path):
    print("\n=== 4. Build picolibc ===")
    if os.path.exists(PICOLIBC_BUILD_DIR):
        shutil.rmtree(PICOLIBC_BUILD_DIR)

    # We link against the just-built compiler-rt
    crt_dir = os.path.dirname(crt_lib_path)

    link_flags = ARCH_FLAGS + [
        "-fuse-ld=lld",
        "-nostdlib",
        f"-L{crt_dir}",
        "-lclang_rt.builtins-riscv32",
    ]

    cross_file = os.path.join(WORK_DIR, "build", "cross_file.txt")
    c_args_str = str(ARCH_FLAGS)
    link_args_str = str(link_flags)

    with open(cross_file, "w") as f:
        f.write(f"""
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
nm = 'llvm-nm'
objcopy = 'llvm-objcopy'
objdump = 'llvm-objdump'
ranlib = 'llvm-ranlib'

[built-in options]
c_args = {c_args_str}
c_link_args = {link_args_str}
cpp_args = {c_args_str}
cpp_link_args = {link_args_str}

[host_machine]
system = 'none'
cpu_family = 'riscv32'
cpu = 'riscv32'
endian = 'little'
""")

    meson_cmd = [
        "meson",
        "setup",
        PICOLIBC_BUILD_DIR,
        PICOLIBC_SRC_DIR,
        f"--cross-file={cross_file}",
        f"--prefix={PICOLIBC_INSTALL_DIR}",
        "-Dmultilib=false",
        "-Dpicocrt=true",
        "-Dspecsdir=none",
        "-Dtests=false",
    ]

    run_cmd(meson_cmd)
    run_cmd(["ninja", "-C", PICOLIBC_BUILD_DIR, "install"])
    print(f"[Success] picolibc installed to {PICOLIBC_INSTALL_DIR}")


def main():
    step0_prepare_dirs()
    step1_prepare_picolibc_src()
    llvm_cmake = step2_prepare_compiler_rt_src()
    crt_lib = step3_build_compiler_rt(llvm_cmake)
    step4_build_picolibc(crt_lib)

    # Optional: Clean up build dir but keep sources
    # shutil.rmtree(os.path.join(WORK_DIR, "build"))


if __name__ == "__main__":
    main()
