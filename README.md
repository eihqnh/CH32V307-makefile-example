
# compile ch32v307 with LLVM toolchain(WCH XW extension)

## build

```bash
#download picolibc & build llvm compiler-rt
python setup.py && make
#or xmake

#flash
#probe-rs run --chip CH32V307 build/example.elf
wlink flash build/exmaple.bin
```

## thanks 

 thanks orignal repo author 

 thanks *ch32-hal* for `riscv32imfc-unknown-none-elf.json`
 
 thanks picolibc
 
 thankis llvm



-----------------------------------------------------
Here is orignal readme

# Basic CH32V307 RISCV Makefile project

Requirements:
 - xpack riscv toolchain (riscv-none-embed-)

Set up udev rules for WCH link
```
sudo cp ./50-wch.rules   /etc/udev/rules.d  
sudo udevadm control --reload-rules
```

Make project
```
make
```


# Licence

Unless otherwise stated files are licensed as BSD 2-Clause

Files under `vendor/` are from openwch (https://github.com/openwch/ch32v307) Licensed under Apache-2.0
Makefile is based on an example here: https://spin.atomicobject.com/2016/08/26/makefile-c-projects/
