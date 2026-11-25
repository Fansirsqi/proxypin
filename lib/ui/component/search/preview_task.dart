import 'dart:async';
import 'dart:isolate';

class PreviewTask<T extends Object> {
  final _result = Completer<T?>();
  RawReceivePort? _port;
  Timer? _timer;
  Isolate? _worker;

  Future<T?> get result => _result.future;

  PreviewTask._();

  static PreviewTask<T> start<T extends Object, I>(
    T Function(I) run,
    I input, {
    required Duration timeout,
    Duration delay = Duration.zero,
  }) {
    final task = PreviewTask<T>._();
    if (delay == Duration.zero) {
      task._start(run, input, timeout);
    } else {
      task._timer = Timer(delay, () => task._start(run, input, timeout));
    }
    return task;
  }

  void _start<I>(T Function(I) run, I input, Duration timeout) {
    final port = _port = RawReceivePort((Object? message) => _finish(message is (T,) ? message.$1 : null));
    _timer = Timer(timeout, cancel);
    Isolate.spawn(
      _runPreviewTask<T, I>,
      (port.sendPort, run, input),
      onError: port.sendPort,
      onExit: port.sendPort,
    ).then<void>((worker) {
      if (_result.isCompleted) {
        worker.kill(priority: Isolate.immediate);
      } else {
        _worker = worker;
      }
    }, onError: (Object _) => cancel());
  }

  void cancel() => _finish(null);

  void _finish(T? value) {
    if (_result.isCompleted) return;
    _timer?.cancel();
    _port?.close();
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _result.complete(value);
  }
}

void _runPreviewTask<T, I>((SendPort, T Function(I), I) job) {
  final (reply, run, input) = job;
  Isolate.exit(reply, (run(input),));
}
