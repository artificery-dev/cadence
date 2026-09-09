import 'dart:ffi';
import 'dart:io';

typedef _GetTidC = Int32 Function();
typedef _GetTidDart = int Function();
typedef _SetPriorityC = Int32 Function(Int32, Uint32, Int32);
typedef _SetPriorityDart = int Function(int, int, int);

/// Ask the kernel to run the calling thread last: `setpriority(PRIO_PROCESS,
/// gettid(), 19)`. Linux only — a thread's nice value is its own there —
/// and best effort: anywhere the call is missing or refused, the thread
/// simply runs at the priority it had. Answers whether it took.
///
/// Every isolate of the library's background work calls this when asked
/// to keep out of the way: the service itself, the scan workers, the
/// artwork worker. On a small machine the interface is on another thread,
/// and this is what keeps it answering while a card is read.
bool lowerThreadPriority() {
  if (!Platform.isLinux) return false;
  try {
    final process = DynamicLibrary.process();
    final gettid = process.lookupFunction<_GetTidC, _GetTidDart>('gettid');
    final setpriority = process.lookupFunction<_SetPriorityC, _SetPriorityDart>(
      'setpriority',
    );
    // PRIO_PROCESS = 0; 19 is the lowest priority nice knows.
    return setpriority(0, gettid(), 19) == 0;
  } on Object {
    return false;
  }
}
