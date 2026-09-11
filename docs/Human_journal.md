



  Liityn ajoissa ja odotan ensimmäistä crash-paluuta:
  $ wsl bash -lc "pkill -9 -f zinux.iso; sleep 2; cd ~/zinux && qemu-system-x86_64 -M q35 -cpu qemu64,+smep,+smap -m 512M -display none -monitor none -serial file:hung9.log -no-reboot -no-shutdown -device isa-debug-exit,iobase=0xf4,iosize=0x04 -drive if=none,id=zbd,format=raw,file=zig-out/zinux-test.img -device virtio-blk-pci,drive=zbd,disable-legacy=on -cdrom zig-out/zinux.iso -s -S -daemonize && sleep 2 && echo LAUNCHED"
  (no output)
  $ wsl bash -lc "ps aux | grep qemu | grep -v grep | wc -l"
  your 131072x1 screen size is bogus. expect trouble
  0
  Thought · 2.2s
  $ wsl bash -lc "cd ~/zinux && qemu-system-x86_64 -M q35 -cpu qemu64,+smep,+smap -m 512M -display none -monitor none -serial file:hung9.log -no-reboot -no-shutdown -device isa-debug-exit,iobase=0xf4,iosize=0x04 -drive if=none,id=zbd,format=raw,file=zig-out/zinux-test.img -device virtio-blk-pci,drive=zbd,disable-legacy=on -cdrom zig-out/zinux.iso -s -S -daemonize && sleep 2 && echo LAUNCHED"
  LAUNCHED
  $ wsl bash -lc "cd ~/zinux && rm -f wscript.txt && printf '%s\n' 'set pagination off' 'file zig-out/bin/zinux-kernel' 'target remote :1234' 'b *0xffffffff8008b05e' 'commands 1' 'silent' 'info registers rip rsp' 'si' 'info registers rip rsp' 'si' 'info registers rip rsp' 'kill' 'quit' 'end' 'continue' > wscript.txt && timeout --foreground -k 10s 240s gdb -batch -x wscript.txt > stepret2.log 2>&1; grep -E 'rip |Breakpoint|Error|error' stepret2.log | head -12; tail -2 hung9.log"
  Breakpoint 1 at 0xffffffff8008b05e: file /home/gigli/zinux/kernel/arch/x86_64/idt.zig, line 177.
  Watchdog captured crash
  Watchdog captured crash
  Thought · 51.0s
  Tarkistan eteneekö boot hitaasti vai onko jumissa:
  $ wsl bash -lc "grep -c captured ~/zinux/hung9.log; tail -3 ~/zinux/hung9.log; grep -E 'Crash captured|restart OK|Full boot' ~/zinux/hung9.log | head -5"
  81
  Watchdog captured crash
  Watchdog captured crash
  Watchdog captured crash
  Thought · 2m 28s
  Thought · 1m 1s
  Lu en plugin-PML40:n – onko matala pää nollattu:
  $ wsl bash -lc "cd ~/zinux && rm -f wscript.txt && printf '%s\n' 'set pagination off' 'file zig-out/bin/zinux-kernel' 'target remote :1234' 'info registers cr3' 'kill' 'quit' > wscript.txt && timeout --foreground -k 10s 60s gdb -batch -x wscript.txt > cr3.log 2>&1; grep -E 'cr3|CR3' cr3.log | head -4"
  cr3            0x201000            [ PDBR=513 PCID=0 ]
  Thought · 44.6s
  Thought · 6.2s
  $ wsl bash -lc "cd ~/zinux && rm -f wscript.txt && printf '%s\n' 'set pagination off' 'file zig-out/bin/zinux-kernel' 'target remote :1234' 'x/1xg 0xffff8000001000' 'x/1xg 0xffff8000001ff8' 'kill' 'quit' > wscript.txt && timeout --foreground -k 10s 60s gdb -batch -x wscript.txt > pml40.log 2>&1; grep -E '0xffff8000001' pml40.log | head -4"
  (no output)
  $ wsl bash -lc "cat ~/zinux/pml40.log | head -12"
  wscript.txt:3: Error in sourced command file:
  could not connect: Connection timed out.
  Thought · 1.5s
  $ wsl bash -lc "cd ~/zinux && qemu-system-x86_64 -M q35 -cpu qemu64,+smep,+smap -m 512M -display none -monitor none -serial file:hung10.log -no-reboot -no-shutdown -device isa-debug-exit,iobase=0xf4,iosize=0x04 -drive if=none,id=zbd,format=raw,file=zig-out/zinux-test.img -device virtio-blk-pci,drive=zbd,disable-legacy=on -cdrom zig-out/zinux.iso -s -daemonize && sleep 2 && echo LAUNCHED"
  qemu-system-x86_64: -device virtio-blk-pci,drive=zbd,disable-legacy=on: Failed to get "write" lock
  Is another process using the image [zig-out/zinux-test.img]?
  $ wsl bash -lc "pkill -9 -f zinux.iso; sleep 3; echo done"
