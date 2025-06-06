import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'channel.dart';
import 'events.dart';
import 'exceptions.dart';
import 'message.dart';

typedef ReceiverCallback = void Function(PushResponse response);

/// Encapsulates the response to a [Push].
class PushResponse {
  /// Builds a PushResponse from a status and response.
  const PushResponse({
    this.status,
    this.response,
  });

  /// Builds a PushResponse from a Map payload.
  ///
  /// Standard is such that the message payload should
  /// be something like
  ///
  /// ```
  /// {
  ///   status: "ok",
  ///   response: {
  ///     foo: "bar"
  ///   }
  /// }
  /// ```
  factory PushResponse.fromMessage(Message message) {
    final data = message.payload;
    return PushResponse(
      status: data?['status'] as String?,
      response: data?['response'],
    );
  }

  /// Status provided by the backend.
  ///
  /// Value is usually either 'ok' or 'error'.
  final String? status;

  /// Arbitrary JSON content provided by the backend.
  final dynamic response;

  /// Whether the response as a 'ok' status.
  bool get isOk => status == 'ok';

  /// Whether the response as a 'error' status.
  bool get isError => status == 'error';

  /// Whether the response as a 'error' status.
  bool get isTimeout => status == 'timeout';

  @override
  bool operator ==(Object other) =>
      other is PushResponse &&
      other.status == status &&
      other.response == response;

  @override
  int get hashCode => Object.hash(status, response);

  @override
  String toString() => 'PushResponse(status: $status, response: $response)';
}

/// Type of function that should return a push payload
typedef PayloadGetter = Map<String, dynamic> Function();

/// Object produced by [PhoenixChannel.push] to encapsulate
/// the message sent and its lifecycle.
class Push {
  /// Build a Push message from its content and associated channel.
  ///
  /// Prefer using [PhoenixChannel.push] instead of using this.
  Push(
    PhoenixChannel channel, {
    this.event,
    this.payload,
    this.timeout,
  })  : _channel = channel,
        _logger = Logger('phoenix_socket.push.${channel.loggerName}'),
        _responseCompleter = Completer<PushResponse>(),
        _binaryPayload = null;

  /// Build a Push message with binary payload from its content and associated channel.
  ///
  /// Prefer using [PhoenixChannel.pushBinary] instead of using this.
  Push.binary(
    PhoenixChannel channel, {
    this.event,
    required Uint8List binaryPayload,
    this.timeout,
  })  : _channel = channel,
        _logger = Logger('phoenix_socket.push.${channel.loggerName}'),
        _responseCompleter = Completer<PushResponse>(),
        payload = null,
        _binaryPayload = binaryPayload;

  final Logger _logger;
  final Map<String, List<ReceiverCallback>> _receivers = {};

  /// The event name associated with the pushed message
  final PhoenixChannelEvent? event;

  /// A getter function that yields the payload of the pushed message,
  /// usually a JSON object.
  final PayloadGetter? payload;

  /// Binary payload for the pushed message.
  final Uint8List? _binaryPayload;

  /// Channel through which the message was sent.
  final PhoenixChannel _channel;

  /// The expected timeout, after which the push is considered failed.
  Duration? timeout;

  PushResponse? _received;
  bool _sent = false;
  bool _awaitingReply = false;
  Timer? _timeoutTimer;
  String? _ref;
  PhoenixChannelEvent? _replyEvent;

  Completer<PushResponse> _responseCompleter;

  /// A future that will yield the response to the original message.
  Future<PushResponse> get future async {
    final response = await _responseCompleter.future;
    if (response.isTimeout) {
      throw ChannelTimeoutException(response);
    }
    return response;
  }

  /// Indicates whether the push has been sent.
  bool get sent => _sent;

  /// The unique identifier of the message used throughout its lifecycle.
  String get ref => _ref ??= _channel.socket.nextRef;

  void _resetRef() {
    _ref = null;
    _replyEvent = null;
  }

  /// The event name of the expected reply coming from the Phoenix backend.
  PhoenixChannelEvent get replyEvent =>
      _replyEvent ??= PhoenixChannelEvent.replyFor(ref);

  /// Returns whether the given status was received from the backend as
  /// a reply.
  bool hasReceived(String status) => _received?.status == status;

  /// Send the push message.
  ///
  /// This also schedules the timeout to be triggered in the future.
  Future<void> send() async {
    if (_received is PushResponse && _received!.isTimeout) {
      _logger.warning('Trying to send push $ref after timeout');
      return;
    }
    _logger.finer('Sending out push for $ref');
    _sent = true;
    _awaitingReply = false;

    startTimeout();
    try {
      late Message message;
      if (_binaryPayload != null) {
        // Create binary message
        message = Message.binary(
          event: event!,
          topic: _channel.topic,
          payload: _binaryPayload!,
          ref: ref,
          joinRef: _channel.joinRef,
        );
      } else {
        // Create regular JSON message
        message = Message(
          event: event!,
          topic: _channel.topic,
          payload: payload!(),
          ref: ref,
          joinRef: _channel.joinRef,
        );
      }
      
      await _channel.socket.sendMessage(message);
      // ignore: avoid_catches_without_on_clauses
    } catch (err, stacktrace) {
      _logger.warning(
        'Caught error for push $ref',
        err,
        stacktrace,
      );
      _receiveResponse(err);
    }
  }

  /// Retry to send the push message.
  ///
  /// This is usually done automatically by the managing [PhoenixChannel]
  /// after a reconnection.
  Future<void> resend(Duration? newTimeout) async {
    timeout = newTimeout ?? timeout;
    if (_sent) {
      reset();
    }
    await send();
  }

  /// Associate a callback to be called if and when a reply with the given
  /// status is received.
  void onReply(String status, ReceiverCallback callback) {
    (_receivers[status] ??= []).add(callback);
  }

  /// Schedule a timeout to be triggered if no reply occurs
  /// within the expected time frame.
  void startTimeout() {
    if (!_awaitingReply) {
      _channel
          .onPushReply(replyEvent)
          .then<void>(_receiveResponse)
          .catchError(_receiveResponse);
      _awaitingReply = true;
    }

    _timeoutTimer ??= Timer(timeout!, () {
      _timeoutTimer = null;
      _logger.warning(() => 'Push $ref timed out');
      _channel.trigger(Message.timeoutFor(ref));
    });
  }

  /// Cancel the scheduled timeout for this push.
  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  /// Reset the scheduled timeout for this push.
  void reset() {
    cancelTimeout();
    _received = null;
    _resetRef();
    _sent = false;
  }

  /// Trigger the appropriate waiters and future associated for this push,
  /// given the provided response.
  ///
  /// This will only trigger the waiters associated with the response's status,
  /// e.g. 'ok' or 'error'.
  void trigger(PushResponse response) {
    _received = response;

    if (_responseCompleter.isCompleted) {
      _logger
        ..warning('Push being completed more than once')
        ..warning(
          () => '  event: $replyEvent, status: ${response.status}',
        )
        ..finer(
          () => '  response: ${response.response}',
        );

      return;
    } else {
      _logger.finer(
        () => 'Completing for $replyEvent with response ${response.response}',
      );
      _responseCompleter.complete(response);
    }

    _logger.finer(() {
      if (_receivers[response.status] case final receiver?
          when receiver.isNotEmpty) {
        return 'Triggering ${receiver.length} callbacks';
      }
      return 'Not triggering any callbacks';
    });

    final receivers = _receivers[response.status]?.toList() ?? const [];
    clearReceivers();
    for (final cb in receivers) {
      cb(response);
    }
  }

  /// Dispose the set of waiters associated with this push.
  void clearReceivers() => _receivers.clear();

  // Remove existing waiters and reset completer
  void cleanUp() {
    if (_sent) {
      _logger.fine('Cleaning up completer');
      clearReceivers();
      _responseCompleter = Completer();
    }
  }

  void _receiveResponse(dynamic response) {
    cancelTimeout();
    if (response is Message) {
      if (response.event == replyEvent) {
        trigger(PushResponse.fromMessage(response));
      }
    } else if (event != PhoenixChannelEvent.join) {
      _logger.finest(
          () => "Completing with error: ${_responseCompleter.hashCode}");
      if (!_responseCompleter.isCompleted) {
        _responseCompleter.completeError(response);
        clearReceivers();
      }
    }
  }
}
