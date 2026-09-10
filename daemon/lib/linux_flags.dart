import 'dart:ffi';

/// Linux UAPI open flags differ on ARM32. Keep this separate from libc calls:
/// https://github.com/torvalds/linux/blob/master/arch/arm/include/uapi/asm/fcntl.h
/// https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/fcntl.h
class LinuxOpenFlags {
  LinuxOpenFlags._(this.directory, this.noFollow, this.largeFile);
  final int directory, noFollow, largeFile;
  static const readWrite = 2, create = 64, closeOnExec = 1 << 19;
  static final current = forAbi(Abi.current());
  static LinuxOpenFlags forAbi(Abi abi) {
    if (abi == Abi.linuxArm) return LinuxOpenFlags._(1 << 14, 1 << 15, 1 << 17);
    if (abi == Abi.linuxIA32)
      return LinuxOpenFlags._(1 << 16, 1 << 17, 1 << 15);
    if (abi == Abi.linuxX64 ||
        abi == Abi.linuxArm64 ||
        abi == Abi.linuxRiscv64) {
      return LinuxOpenFlags._(1 << 16, 1 << 17, 0);
    }
    throw UnsupportedError('Linux open flags have not been audited for $abi');
  }

  int get directoryRead => directory | noFollow | closeOnExec | largeFile;
  int writable({required bool createFile}) =>
      readWrite |
      noFollow |
      closeOnExec |
      largeFile |
      (createFile ? create : 0);
}
