#import "RemoteViewController.h"
#import "AppController.h"
#include <QuartzCore/CAAnimation.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <iostream>
#include <netdb.h>

using namespace std;

RemoteViewController *gRemoteViewController = nil;

#define BS_REMOTE_PROTOCOL_VERSION 121

// how much larger than the button/dpad areas we should count touch events in
#define BUTTON_BUFFER 2.0
#define DPAD_BUFFER 1.2

#define DPAD_DRAG_DIST                                                         \
  0.25 // how far we must be from the dpad before it follows us
#define DPAD_FULL_SPEED_DIST 0.35
#define DPAD_FULL_SPEED_DIST_FLOATING 0.15

#define DPAD_FULL_SPEED_DIST_TILT 0.1

#define DPAD_NEUTRAL_Y 0

enum BSRemoteError {
  BS_REMOTE_ERROR_VERSION_MISMATCH,
  BS_REMOTE_ERROR_GAME_SHUTTING_DOWN,
  BS_REMOTE_ERROR_NOT_ACCEPTING_CONNECTIONS,
  BS_REMOTE_ERROR_NOT_CONNECTED
};

// component masks for 16 bit state values
enum BSRemoteState {
  BS_REMOTE_STATE_PUNCH = 1 << 0,
  BS_REMOTE_STATE_JUMP = 1 << 1,
  BS_REMOTE_STATE_THROW = 1 << 2,
  BS_REMOTE_STATE_BOMB = 1 << 3,
  BS_REMOTE_STATE_MENU = 1 << 4,
  // (bits 6-10 are d-pad h-value and bits 11-15 are dpad v-value)
  BS_REMOTE_STATE_HOLD_POSITION = 1 << 15
};

enum BSRemoteState2 {
  BS_REMOTE_STATE2_MENU = 1 << 0,
  BS_REMOTE_STATE2_JUMP = 1 << 1,
  BS_REMOTE_STATE2_PUNCH = 1 << 2,
  BS_REMOTE_STATE2_THROW = 1 << 3,
  BS_REMOTE_STATE2_BOMB = 1 << 4,
  BS_REMOTE_STATE2_RUN = 1 << 5,
  BS_REMOTE_STATE2_FLY = 1 << 6,
  BS_REMOTE_STATE2_HOLD_POSITION = 1 << 7
};

@interface RemoteViewController ()
- (void)tryToDie;
- (void)leave;
- (void)readFromSocket:(int)i;
- (void)sendIdRequest;
- (void)doStateChangeForced:(BOOL)forced;
- (void)shipUnAckedStatesV1;
- (void)shipUnAckedStatesV2;
- (CGPoint)getPointInImageSpace:(UIView *)image forPoint:(CGPoint)p;
- (void)setDPadX:(float)x
            andY:(float)y
      andPressed:(BOOL)pressed
       andDirect:(BOOL)direct;
- (void)updateButtonsForTouches;
- (void)updateDPadBase;
- (void)axisSnappingChanged:(NSNumber *)enabled;
- (void)showPrefs;
- (void)showActivityIndicator;
@end

@implementation RemoteViewController

@synthesize processTimer = _processTimer;
@synthesize buttonBacking = _buttonBacking;
@synthesize buttonImagePunch = _buttonImagePunch;
@synthesize buttonImagePunchPressed = _buttonImagePunchPressed;
@synthesize buttonImageThrow = _buttonImageThrow;
@synthesize buttonImageThrowPressed = _buttonImageThrowPressed;
@synthesize buttonImageJump = _buttonImageJump;
@synthesize buttonImageJumpPressed = _buttonImageJumpPressed;
@synthesize buttonImageBomb = _buttonImageBomb;
@synthesize buttonImageBombPressed = _buttonImageBombPressed;
@synthesize dPadBacking = _dPadBacking;
@synthesize dPadThumbImage = _dPadThumbImage;
@synthesize dPadThumbPressedImage = _dPadThumbPressedImage;
@synthesize dPadCenterImage = _dPadCenterImage;
@synthesize bgImage = _bgImage;
@synthesize activityIndicator = _activityIndicator;
@synthesize lagMeter = _lagMeter;
@synthesize validTouches = _validTouches;
@synthesize validMovedTouches = _validMovedTouches;

static void readCallback(CFSocketRef cfSocket, CFSocketCallBackType type,
                         CFDataRef address, const void *data, void *info) {
  RemoteViewController *rvc = (RemoteViewController *)info;
  int s = CFSocketGetNative(cfSocket);
  if (s) {
    [rvc readFromSocket:s];
  }
}

+ (RemoteViewController *)sharedRemoteViewController {
  return gRemoteViewController;
}

- (void)initCommon {
  _ping = 0.0;

  _dPadStateH = 0.0;
  _dPadStateV = 0.0;

  _wantToDie = NO;

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  _axisSnapping = [defaults objectForKey:@"axisSnapping"] == nil
                      ? NO
                      : [defaults boolForKey:@"axisSnapping"];

  _tiltMode = [defaults objectForKey:@"tiltMode"] == nil
                  ? NO
                  : [defaults boolForKey:@"tiltMode"];
  _floating = [defaults objectForKey:@"joystickFloating"] == nil
                  ? YES
                  : [defaults boolForKey:@"joystickFloating"];

  _controllerDPadSensitivity =
      [defaults objectForKey:@"controllerDPadSensitivity"] == nil
          ? DEFAULT_CONTROLLER_DPAD_SENSITIVITY
          : [defaults floatForKey:@"controllerDPadSensitivity"];

  _joystickSize = [defaults objectForKey:@"joystickSize"] == nil
                      ? 1.0
                      : [defaults floatForKey:@"joystickSize"];

  _tiltNeutralY = [defaults objectForKey:@"tiltNeutralY"] == nil
                      ? -0.8
                      : [defaults floatForKey:@"tiltNeutralY"];
  _tiltNeutralZ = [defaults objectForKey:@"tiltNeutralZ"] == nil
                      ? -0.7
                      : [defaults floatForKey:@"tiltNeutralZ"];

  self.validTouches = [NSMutableSet setWithCapacity:10];
  self.validMovedTouches = [NSMutableSet setWithCapacity:10];

  _lastContactTime = _lastNullStateTime = CACurrentMediaTime();

  BOOL success = NO;

  _id = -1; // aint got one
  _idRequestKey = ((long)(CACurrentMediaTime() * 1000.0)) % 10000;

  // if we're reconnecting we might get acks for states we didnt send, so put
  // something reasonable here or we'll screw up our lag-meter
  CFTimeInterval curTime = CACurrentMediaTime();
  for (int i = 0; i < 256; i++) {
    _stateBirthTimes[i] = curTime;
    _stateLastSentTimes[i] = 0.0;
  }

  // Should we be trying to do a v4 or v6 address first?...
  // are there downsides to preferring v6?

  // try handling ipv6
  {
    // create our datagram socket...
    CFSocketContext socketCtxt = {0, self, NULL, NULL, NULL};
    _cfSocket6 = CFSocketCreate(kCFAllocatorDefault, PF_INET6, SOCK_DGRAM,
                                IPPROTO_UDP, kCFSocketReadCallBack,
                                (CFSocketCallBack)&readCallback, &socketCtxt);

    if (_cfSocket6 == NULL) {
      NSLog(@"ERROR CREATING V6 SOCKET");
      abort();
    }

    // bind it...
    struct sockaddr_in6 addr6;
    memset(&addr6, 0, sizeof(addr6));
    addr6.sin6_len = sizeof(addr6);
    addr6.sin6_family = AF_INET6;
    addr6.sin6_port = 0;
    addr6.sin6_flowinfo = 0;
    addr6.sin6_addr = in6addr_any;
    NSData *address6 = [NSData dataWithBytes:&addr6 length:sizeof(addr6)];

    if (kCFSocketSuccess !=
        CFSocketSetAddress(_cfSocket6, (CFDataRef)address6)) {
      NSLog(@"ERROR ON CFSocketSetAddress for ipv6 socket");
      if (_cfSocket6) {
        CFRelease(_cfSocket6);
      }
      _cfSocket6 = NULL;
    }
    if (_cfSocket6 != NULL) {
      _socket6 = CFSocketGetNative(_cfSocket6);

      // set up a run loop source for the socket
      CFRunLoopRef cfrl = CFRunLoopGetCurrent();
      CFRunLoopSourceRef source =
          CFSocketCreateRunLoopSource(kCFAllocatorDefault, _cfSocket6, 0);
      CFRunLoopAddSource(cfrl, source, kCFRunLoopCommonModes);
      CFRelease(source);
      success = YES;
    }
  }

  // try v4 ones...
  {

    // create our datagram socket...
    CFSocketContext socketCtxt = {0, self, NULL, NULL, NULL};
    _cfSocket4 = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_DGRAM,
                                IPPROTO_UDP, kCFSocketReadCallBack,
                                (CFSocketCallBack)&readCallback, &socketCtxt);
    ;

    if (_cfSocket4 == NULL) {
      NSLog(@"ERROR CREATING V4 SOCKET");
      abort();
    }

    if (_cfSocket4 != NULL) {
      // bind it...
      struct sockaddr_in addr4;
      memset(&addr4, 0, sizeof(addr4));
      addr4.sin_len = sizeof(addr4);
      addr4.sin_family = AF_INET;
      addr4.sin_port = 0;
      addr4.sin_addr.s_addr = htonl(INADDR_ANY);
      NSData *address4 = [NSData dataWithBytes:&addr4 length:sizeof(addr4)];

      if (kCFSocketSuccess !=
          CFSocketSetAddress(_cfSocket4, (CFDataRef)address4)) {
        NSLog(@"ERROR ON CFSocketSetAddress for ipv4 socket\n");
        if (_cfSocket4) {
          CFRelease(_cfSocket4);
        }
        _cfSocket4 = NULL;
      }
      if (_cfSocket4 != NULL) {
        _socket4 = CFSocketGetNative(_cfSocket4);

        // set up a run loop source for the socket
        CFRunLoopRef cfrl = CFRunLoopGetCurrent();
        CFRunLoopSourceRef source =
            CFSocketCreateRunLoopSource(kCFAllocatorDefault, _cfSocket4, 0);
        CFRunLoopAddSource(cfrl, source, kCFRunLoopCommonModes);
        CFRelease(source);
        success = YES;
      }
    }
  }
  [self sendIdRequest];

  self.processTimer =
      [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)(1.0 / 10.0)
                                       target:self
                                     selector:@selector(process)
                                     userInfo:nil
                                      repeats:TRUE];

  if (!success) {
    NSLog(@"Couldn't connect.");
    [self tryToDie];
  }
}

- (id)initWithAddress:(struct sockaddr *)addr andSize:(int)sz {
  gRemoteViewController = self;
  [super init];
  _newStyle = YES;
  _addrCount = 1;

  if (true) {
    char buffer[INET6_ADDRSTRLEN];
    int err = getnameinfo((struct sockaddr *)addr, sz, buffer, sizeof(buffer),
                          0, 0, NI_NUMERICHOST);
    if (err == 0) {
      NSLog(@"Connecting to %s", buffer);
    }
  }
  memcpy(&_addresses[0], addr, sz);
  _addressSizes[0] = sz;
  [self initCommon];
  return self;
}

- (void)doBecomeActive {
  _lastContactTime = CACurrentMediaTime();
  [self showActivityIndicator];
}

- (void)sendIdRequest {
  // lets include a name with our id-requests..

  char buffer[100];
  NSString *dName;

  NSString *uidString;
  if ([[UIDevice currentDevice]
          respondsToSelector:@selector(identifierForVendor)]) {
    uidString = [[UIDevice currentDevice].identifierForVendor UUIDString];
  } else {
    uidString = nil;
  }

  // on newer versions we send a hash at the end of our name to uniquely
  // identify us (this is less necessary here on the iOS version since most
  // phones have unique names, but on android/etc just the device name is used
  // as the name.
  NSString *name = [AppController playerName];
  // we use # for a special purpose so gotta clear them out...
  name = [name stringByReplacingOccurrencesOfString:@"#" withString:@""];

  if (_newStyle and uidString != nil) {
    dName = [NSString stringWithFormat:@"%@#%@", name, uidString];
  } else {
    dName = [UIDevice currentDevice].name;
  }
  strncpy(buffer, dName.UTF8String, sizeof(buffer));
  buffer[sizeof(buffer) - 1] = 0; // make sure its capped in case it overran..

  int nameLen = static_cast<int>(strlen(buffer));

  // we shoot ID requests out on all our addresses we have for the host..
  // (then whichever one comes back first is what we use)
  for (unsigned int i = 0; i < _addrCount; i++) {

    // only send to the addresses matching the family of the socket we made...
    struct sockaddr *sa = (sockaddr *)&_addresses[i];
    UInt8 data[5 + nameLen];
    data[0] = BS_REMOTE_MSG_ID_REQUEST;

    // old protocol version - cant really change this cleanly without breaking
    // things so we now use data[4]
    data[1] = BS_REMOTE_PROTOCOL_VERSION;

    *(short *)&data[2] = _idRequestKey;

    // this is now used for protocol version *request* - specifying 50
    // means we want version 2 (yes, it's ugly; i know)
    data[4] = 50;

    strncpy((char *)data + 5, buffer, nameLen);
    int s;
    if (sa->sa_family == AF_INET6) {
      s = _socket6;
    } else if (sa->sa_family == AF_INET) {
      s = _socket4;
    } else {
      abort();
    }

    int err = static_cast<int>(sendto(
        s, data, 5 + nameLen, 0, (sockaddr *)&_addresses[i], _addressSizes[i]));
    if (err == -1)
      NSLog(@"ERROR %d on sendto for %d\n", errno, i);
  }
  _waitingForIDResponse = YES;
}

- (void)process {
  if (_wantToDie) {
    [self tryToDie];
    return;
  }

  CFTimeInterval t = CACurrentMediaTime();

  // if we're trying to leave but havn't received an ack, keep sending
  // disconnects out
  if (_wantToLeave) {

    // give up after a short while
    if (t - _leavingStartTime > 2.0) {
      [self tryToDie];
      return;
    }

    // fire off another disconnect notice
    if (_id != -1) {
      UInt8 data[2] = {BS_REMOTE_MSG_DISCONNECT, _id};
      if (_haveV4) {
        send(_socket4, data, sizeof(data), 0);
      }
      if (_haveV6) {
        send(_socket6, data, sizeof(data), 0);
      }
    }
  }

  // if we've got states we havn't heard an ack for yet, keep shipping 'em out
  UInt8 stateDiff = _requestedState - _nextState;

  // if they've requested a state we don't have yet, we don't need to resend
  // anything
  if (stateDiff < 128) {
    // .. however we wanna shoot states at the server every now and then even if
    // we have no new states, to keep from timing out and such..
    if (t - _lastNullStateTime > 3.0) {
      [self doStateChangeForced:YES];
      _lastNullStateTime = t;
    }
  } else {
    // ok we've got at least one state we havn't heard confirmation for yet..
    // lets ship 'em out..
    if (_usingProtocolV2) {
      [self shipUnAckedStatesV2];
    } else {
      [self shipUnAckedStatesV1];
    }
  }

  // if we don't have an ID yet, keep sending off those requests...
  if (_id == -1) {
    [self sendIdRequest];
  }

  // update our lag meter every so often
  if (t - _lastLagUpdateTime > 2.0) {
    float smoothing = 0.5;
    _averageLag = smoothing * _averageLag + (1.0 - smoothing) * _currentLag;

    // lets show half of our the round-trip time as lag.. (the actual delay
    // in-game is just our packets getting to them; not the round trip)

    float val = _averageLag * 0.5;

    if (val < 0.1) {
      _lagMeter.textColor = [UIColor colorWithRed:0.5
                                            green:1.0
                                             blue:0.5
                                            alpha:1.0];
    } else if (val < 0.2) {
      _lagMeter.textColor = [UIColor colorWithRed:1.0
                                            green:0.7
                                             blue:0.4
                                            alpha:1.0];
    } else {
      _lagMeter.textColor = [UIColor colorWithRed:1.0
                                            green:0.4
                                             blue:0.4
                                            alpha:1.0];
    }

    _lagMeter.text = [NSString stringWithFormat:@"lag: %.2f", val];
    _currentLag = 0.0;
    _lastLagUpdateTime = t;
  }
}

- (void)readFromSocket:(int)s {
  unsigned char buffer[10];
  sockaddr_in6 addr;
  socklen_t l = sizeof(addr);
  int amt = static_cast<int>(
      recvfrom(s, buffer, sizeof(buffer), 0, (sockaddr *)&addr, &l));

  if (amt == -1) {
    // connrefused on a udp socket means the other end is dead
    if (errno == ECONNREFUSED) {
      [AppController debugPrint:@"The game has shut down."];
      [self tryToDie];
      return;
    }

    if (!_wantToLeave and !_wantToDie) {
#if DEBUG
      NSLog(@"ERROR ON RECVFROM: %d; DYING!\n", errno);
#endif // DEBUG
      [AppController debugPrint:@"Network error;"];
      [AppController debugPrint:@"Try restarting BombSquad."];
    }
    [self tryToDie];
    return;
  }

  if (amt > 0) {
    switch (buffer[0]) {
    case BS_REMOTE_MSG_ID_RESPONSE: {
      if (amt == 3) {

        if (!_waitingForIDResponse) {
          break;
        }
        int s;
        if (((sockaddr *)&addr)->sa_family == AF_INET and not _haveV4) {
          s = _socket4;
        } else if (not _haveV6) {
          s = _socket6;
        } else {
          break;
        }
        _nextState = 0; // start over with this ID
        if (connect(s, (sockaddr *)&addr, l) != 0) {
          NSLog(@"Warning: socket connect failed with error %d\n.", errno);
          break;
        } else {
          if (((sockaddr *)&addr)->sa_family == AF_INET) {
            _haveV4 = TRUE;
          } else {
            _haveV6 = TRUE;
          }
        }
        _connected = YES;
        _waitingForIDResponse = NO;
        [self.activityIndicator removeFromSuperview];
        self.activityIndicator = nil;
      }
      // hooray we have an id.. we're now officially 'joined'
      _id = buffer[1];

      // we told them we support protocol v2.. if they respond with 100, they do
      // too.
      _usingProtocolV2 = (buffer[2] == 100);
      break;
    }
    case BS_REMOTE_MSG_STATE_ACK: {
      if (amt == 2) {
        // take note that we heard from them for time-out purposes
        CFTimeInterval time = CACurrentMediaTime();
        _lastContactTime = time;

        // if we've got an activity indicator up, kill it
        if (self.activityIndicator != nil) {
          [self.activityIndicator removeFromSuperview];
          self.activityIndicator = nil;
        }

        // take note of the next state they want...
        // move ours up to that point (if we havn't yet)
        UInt8 stateDiff = buffer[1] - _requestedState;
        if (stateDiff > 0 and stateDiff < 128) {
          _requestedState += (stateDiff - 1);
          CFTimeInterval lag = time - _stateBirthTimes[_requestedState];
          if (lag > _currentLag) {
            _currentLag = lag;
          }
          _requestedState++;
          assert(_requestedState == buffer[1]);
        }
      }
      break;
    }
    case BS_REMOTE_MSG_DISCONNECT_ACK:

      // means we were trying to disconnect and have been successful.
      if (amt == 1) {
        [self tryToDie];
      }
      break;

    case BS_REMOTE_MSG_DISCONNECT: {
      if (amt == 2) {
        if (buffer[1] == BS_REMOTE_ERROR_VERSION_MISMATCH) {
          [AppController debugPrint:@"Version Mismatch;"];
          [AppController
              debugPrint:@"Make sure BombSquad and BombSquad Remote"];
          [AppController debugPrint:@"are the latest versions."];
        } else if (buffer[1] == BS_REMOTE_ERROR_GAME_SHUTTING_DOWN) {
          [AppController debugPrint:@"The game has shut down."];
        } else if (buffer[1] == BS_REMOTE_ERROR_NOT_ACCEPTING_CONNECTIONS) {
          [AppController debugPrint:@"The game is not accepting connections."];
        } else {
          if (!_wantToDie and !_wantToLeave) {
            [AppController debugPrint:@"Disconnected by server."];
          }
        }
        [self tryToDie];
      }
      break;
    }
    default:
      NSLog(@"UNKNOWN MSG IN TYPE %d\n", buffer[0]);
      break;
    }
  }
}

- (void)shipUnAckedStatesV2 {
  CFTimeInterval curTime = CACurrentMediaTime();

  _lastSendTime = curTime;

  // ok we need to ship out everything from their last requested state
  // to our current state.. (clamping at a reasonable value)
  if (_id != -1) {

    UInt8 statesToSend = _nextState - _requestedState;
    if (statesToSend > 11) {
      statesToSend = 11;
    }
    if (statesToSend < 1) {
      return;
    }

    UInt8 data[150];
    data[0] = BS_REMOTE_MSG_STATE2;
    data[1] = _id;
    data[2] = statesToSend; // number of states we have here

    UInt8 s = _nextState - statesToSend;

    data[3] = s; // starting index

    // pack em in
    int retransmitCount = 0;
    UInt8 *val = (UInt8 *)(data + 4);
    for (int i = 0; i < statesToSend; i++) {
      val[0] = _statesV2[s] & 0xFF;
      val[1] = (_statesV2[s] >> 8) & 0xFF;
      val[2] = (_statesV2[s] >> 16) & 0xFF;
      if (_stateLastSentTimes[s] != 0.0) {
        retransmitCount++;
      }
      _stateLastSentTimes[s] = curTime;
      s++;
      val += 3;
    }
    if (_haveV4) {
      int err = static_cast<int>(send(_socket4, data, 4 + 3 * statesToSend, 0));
      if (err == -1)
        NSLog(@"ERROR %d on v4 sendto\n", errno);
    }
    if (_haveV6) {
      int err = static_cast<int>(send(_socket6, data, 4 + 3 * statesToSend, 0));
      if (err == -1) {
        NSLog(@"ERROR %d on v6 sendto\n", errno);
      }
    }
  }
}

- (void)shipUnAckedStatesV1 {
  CFTimeInterval curTime = CACurrentMediaTime();

  _lastSendTime = curTime;

  // ok we need to ship out everything from their last requested state
  // to our current state.. (clamping at a reasonable value)
  if (_id != -1) {

    UInt8 statesToSend = _nextState - _requestedState;
    if (statesToSend > 11) {
      statesToSend = 11;
    }
    if (statesToSend < 1) {
      return;
    }

    UInt8 data[100];
    data[0] = BS_REMOTE_MSG_STATE;
    data[1] = _id;
    data[2] = statesToSend; // number of states we have here

    UInt8 s = _nextState - statesToSend;

    data[3] = s; // starting index

    // pack em in
    int retransmitCount = 0;
    UInt16 *val = (UInt16 *)(data + 4);
    for (int i = 0; i < statesToSend; i++) {
      *val = _statesV1[s];
      if (_stateLastSentTimes[s] != 0.0) {
        retransmitCount++;
      }
      _stateLastSentTimes[s] = curTime;
      s++;
      val++;
    }
    if (_haveV4) {
      int err = static_cast<int>(send(_socket4, data, 4 + 2 * statesToSend, 0));
      if (err == -1) {
        NSLog(@"ERROR %d on v4 sendto\n", errno);
      }
    }
    if (_haveV6) {
      int err = static_cast<int>(send(_socket6, data, 4 + 2 * statesToSend, 0));
      if (err == -1) {
        NSLog(@"ERROR %d on v6 sendto\n", errno);
      }
    }
  }
}

- (void)_doStateChangeV2Forced:(BOOL)force {
  if (_wantToDie) {
    [self tryToDie];
    return;
  }

  // compile our state value

  UInt32 s = _buttonStateV2; // buttons

  int hVal = (int)(256.0f * (0.5f + _dPadStateH * 0.5f));
  if (hVal < 0) {
    hVal = 0;
  } else if (hVal > 255) {
    hVal = 255;
  }

  int vVal = (int)(256.0f * (0.5f + _dPadStateV * 0.5f));
  if (vVal < 0) {
    vVal = 0;
  } else if (vVal > 255) {
    vVal = 255;
  }

  s |= hVal << 8;
  s |= vVal << 16;

  // if our compiled state value hasn't changed, don't send.
  // (analog joystick noise can send a bunch of redundant states through here)
  // The exception is if forced is true, which is the case with packets that
  // double as keepalives.
  if (s == _lastSentState and not force) {
    return;
  }

  _stateBirthTimes[_nextState] = CACurrentMediaTime();
  _stateLastSentTimes[_nextState] = 0;

  _statesV2[_nextState++] = s;
  _lastSentState = s;

  // if we're pretty up to date as far as state acks, lets go ahead
  // and send out this state immediately..
  // (keeps us nice and responsive on low latency networks)

  UInt8 unackedCount = _nextState - _requestedState;
  if (unackedCount < 3) {
    [self shipUnAckedStatesV2];
  }
}

- (void)_doStateChangeV1Forced:(BOOL)force {
  if (_wantToDie) {
    [self tryToDie];
    return;
  }

  // compile our state value
  int s = _buttonStateV1;                                         // buttons
  s |= (_dPadStateH > 0) << 5;                                    // sign bit
  s |= ((int)(round(fmin(1.0, fabs(_dPadStateH)) * 15.0))) << 6;  // mag
  s |= (_dPadStateV > 0) << 10;                                   // sign bit
  s |= ((int)(round(fmin(1.0, fabs(_dPadStateV)) * 15.0))) << 11; // mag

  // if our compiled state value hasn't changed, don't send.
  // (analog joystick noise can send a bunch of redundant states through here)
  // The exception is if forced is true, which is the case with packets that
  // double as keepalives.
  if (s == _lastSentState and not force) {
    return;
  }

  _stateBirthTimes[_nextState] = CACurrentMediaTime();
  _stateLastSentTimes[_nextState] = 0;

  _statesV1[_nextState++] = s;
  _lastSentState = s;

  // if we're pretty up to date as far as state acks, lets go ahead
  // and send out this state immediately..
  // (keeps us nice and responsive on low latency networks)
  UInt8 unackedCount = _nextState - _requestedState;
  if (unackedCount < 3) {
    [self shipUnAckedStatesV1];
  }
}

- (void)doStateChangeForced:(BOOL)force {
  if (_usingProtocolV2)
    [self _doStateChangeV2Forced:force];
  else
    [self _doStateChangeV1Forced:force];
}

- (void)handleUpPress {
  _dPadStateV = -1.0;
  [self doStateChangeForced:NO];
}

- (void)handleUpRelease {
  _dPadStateV = 0.0;
  [self doStateChangeForced:NO];
}

- (void)handleDownPress {
  _dPadStateV = 1.0;
  [self doStateChangeForced:NO];
}

- (void)handleDownRelease {
  _dPadStateV = 0.0;
  [self doStateChangeForced:NO];
}

- (void)handleLeftPress {
  _dPadStateH = -1.0;
  [self doStateChangeForced:NO];
}

- (void)handleLeftRelease {
  _dPadStateH = 0.0;
  [self doStateChangeForced:NO];
}

- (void)handleRightPress {
  _dPadStateH = 1.0;
  [self doStateChangeForced:NO];
}

- (void)handleRightRelease {
  _dPadStateH = 0.0;
  [self doStateChangeForced:NO];
}

- (void)handlePunchPress {
  _buttonStateV1 |= BS_REMOTE_STATE_PUNCH;
  _buttonStateV2 |= BS_REMOTE_STATE2_PUNCH;
  [self doStateChangeForced:NO];
  self.buttonImagePunchPressed.hidden = NO;
  self.buttonImagePunch.hidden = YES;
}

- (void)handlePunchRelease {
  _buttonStateV1 &= ~BS_REMOTE_STATE_PUNCH;
  _buttonStateV2 &= ~BS_REMOTE_STATE2_PUNCH;
  [self doStateChangeForced:NO];
  self.buttonImagePunchPressed.hidden = YES;
  self.buttonImagePunch.hidden = NO;
}

- (void)handleJumpPress {
  _buttonStateV1 |= BS_REMOTE_STATE_JUMP;
  _buttonStateV2 |= BS_REMOTE_STATE2_JUMP;
  [self doStateChangeForced:NO];
  self.buttonImageJump.hidden = YES;
  self.buttonImageJumpPressed.hidden = NO;
}

- (void)handleJumpRelease {
  _buttonStateV1 &= ~BS_REMOTE_STATE_JUMP;
  _buttonStateV2 &= ~BS_REMOTE_STATE2_JUMP;
  [self doStateChangeForced:NO];
  self.buttonImageJump.hidden = NO;
  self.buttonImageJumpPressed.hidden = YES;
}

- (void)handleThrowPress {
  _buttonStateV1 |= BS_REMOTE_STATE_THROW;
  _buttonStateV2 |= BS_REMOTE_STATE2_THROW;
  [self doStateChangeForced:NO];
  self.buttonImageThrow.hidden = YES;
  self.buttonImageThrowPressed.hidden = NO;
}

- (void)handleThrowRelease {
  _buttonStateV1 &= ~BS_REMOTE_STATE_THROW;
  _buttonStateV2 &= ~BS_REMOTE_STATE2_THROW;
  [self doStateChangeForced:NO];
  self.buttonImageThrow.hidden = NO;
  self.buttonImageThrowPressed.hidden = YES;
}

- (void)handleBombPress {
  _buttonStateV1 |= BS_REMOTE_STATE_BOMB;
  _buttonStateV2 |= BS_REMOTE_STATE2_BOMB;
  [self doStateChangeForced:NO];
  self.buttonImageBomb.hidden = YES;
  self.buttonImageBombPressed.hidden = NO;
}

- (void)handleBombRelease {
  _buttonStateV1 &= ~BS_REMOTE_STATE_BOMB;
  _buttonStateV2 &= ~BS_REMOTE_STATE2_BOMB;
  [self doStateChangeForced:NO];
  self.buttonImageBomb.hidden = NO;
  self.buttonImageBombPressed.hidden = YES;
}

- (void)handleRun1Press {
  _run1Pressed = true;
  if (_run1Pressed || _run2Pressed || _run3Pressed || _run4Pressed) {
    _buttonStateV2 |= BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleRun1Release {
  _run1Pressed = false;
  if (!_run1Pressed and !_run2Pressed and !_run3Pressed and !_run4Pressed) {
    _buttonStateV2 &= ~BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleRun2Press {
  _run2Pressed = true;
  if (_run1Pressed || _run2Pressed || _run3Pressed || _run4Pressed) {
    _buttonStateV2 |= BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleRun2Release {
  _run2Pressed = false;
  if (!_run1Pressed and !_run2Pressed and !_run3Pressed and !_run4Pressed) {
    _buttonStateV2 &= ~BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleRun3Press {
  _run3Pressed = true;
  if (_run1Pressed || _run2Pressed || _run3Pressed || _run4Pressed) {
    _buttonStateV2 |= BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleRun3Release {
  _run3Pressed = false;
  if (!_run1Pressed and !_run2Pressed and !_run3Pressed and !_run4Pressed) {
    _buttonStateV2 &= ~BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleRun4Press {
  _run4Pressed = true;
  if (_run1Pressed || _run2Pressed || _run3Pressed || _run4Pressed) {
    _buttonStateV2 |= BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleRun4Release {
  _run4Pressed = false;
  if (!_run1Pressed and !_run2Pressed and !_run3Pressed and !_run4Pressed) {
    _buttonStateV2 &= ~BS_REMOTE_STATE2_RUN;
  }
  [self doStateChangeForced:NO];
}

- (void)handleMenu {
  // send 2 state-changes (menu-down and menu-up)
  _buttonStateV1 |= BS_REMOTE_STATE_MENU;
  _buttonStateV2 |= BS_REMOTE_STATE2_MENU;
  [self doStateChangeForced:NO];
  _buttonStateV1 &= ~BS_REMOTE_STATE_MENU;
  _buttonStateV2 &= ~BS_REMOTE_STATE2_MENU;
  [self doStateChangeForced:NO];
}

- (void)viewDidLoad {
  [super viewDidLoad];

  [self.view setMultipleTouchEnabled:YES];

  float width = self.view.bounds.size.width;
  float height = self.view.bounds.size.height;

  if (@available(iOS 11.0, *)) {

    width =
        width - UIApplication.sharedApplication.keyWindow.safeAreaInsets.left;
  }

  UIImageView *i;
  CGRect f;

  self.buttonBacking = [[[UIView alloc] init] autorelease];
  self.buttonImagePunch = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonPunch.png"]] autorelease];
  self.buttonImagePunchPressed = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonPunchPressed.png"]]
      autorelease];
  self.buttonImageThrow = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonThrow.png"]] autorelease];
  self.buttonImageThrowPressed = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonThrowPressed.png"]]
      autorelease];
  self.buttonImageJump = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonJump.png"]] autorelease];
  self.buttonImageJumpPressed = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonJumpPressed.png"]]
      autorelease];
  self.buttonImageBomb = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonBomb.png"]] autorelease];
  self.buttonImageBombPressed = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"buttonBombPressed.png"]]
      autorelease];
  self.dPadBacking = [[[UIView alloc] init] autorelease];
  self.dPadThumbImage = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"thumb.png"]] autorelease];
  self.dPadThumbPressedImage = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"thumbPressed.png"]] autorelease];
  self.dPadCenterImage = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"center.png"]] autorelease];

  self.bgImage = [[[UIImageView alloc]
      initWithImage:[UIImage imageNamed:@"controllerBG.png"]] autorelease];
  _bgImage.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _bgImage.frame = self.view.bounds;
  _bgImage.opaque = YES;
  [self.view addSubview:_bgImage];

  // use raw width for lag meter so we don't get skewed to the side due to notch
  CGFloat lagMeterXAxis = (self.view.bounds.size.width - 60) / 2.0;
  CGFloat lagMeterYAxis = height - 12;

  if (@available(iOS 11.0, *)) {
    lagMeterYAxis =
        lagMeterYAxis -
        UIApplication.sharedApplication.keyWindow.safeAreaInsets.bottom;
  }

  self.lagMeter = [[UILabel alloc] init];
  _lagMeter.frame = CGRectMake(lagMeterXAxis, lagMeterYAxis, 60, 12);
  _lagMeter.textAlignment = NSTextAlignmentCenter;
  _lagMeter.textColor = [UIColor clearColor];
  _lagMeter.backgroundColor = [UIColor clearColor];
  _lagMeter.font = [UIFont boldSystemFontOfSize:10];
  _lagMeter.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                               UIViewAutoresizingFlexibleRightMargin |
                               UIViewAutoresizingFlexibleTopMargin;
  _lastLagUpdateTime = CACurrentMediaTime();

  [self.view addSubview:_lagMeter];
  _lagMeter.text = @"testing";

  UIButton *b;
  float buttonWidth = 80;
  float buttonHeight = 60;

  // dpad
  {

    CGRect fBase;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
      fBase = CGRectMake(0, height / 2 - 120, 200, 200);
    } else if (@available(iOS 11.0, *)) {
      fBase = CGRectMake(
          UIApplication.sharedApplication.keyWindow.safeAreaInsets.left * 2,
          height * 0.65 - 120, 200, 200);
    } else {
      // fBase = CGRectMake(0,height - 240,200,200);
      fBase = CGRectMake(0, height * 0.65 - 120, 200, 200);
    }

    UIView *v = self.dPadBacking;
    // backing
    v.frame = fBase;
    v.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleRightMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:v];

    float thumbSize = 128 * _joystickSize;
    float centerSize = 256 * _joystickSize;
    float ins;

    // center
    i = self.dPadCenterImage;
    f = fBase;
    ins = (fBase.size.width - centerSize) * 0.5;
    f = CGRectInset(f, ins, ins);
    f.origin.x -= _dPadBacking.frame.origin.x;
    f.origin.y -= _dPadBacking.frame.origin.y;
    i.frame = f;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleRightMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_dPadBacking addSubview:i];

    // thumb
    i = self.dPadThumbImage;
    f = fBase;
    ins = (fBase.size.width - thumbSize) * 0.5;
    f = CGRectInset(f, ins, ins);
    f.origin.x -= _dPadBacking.frame.origin.x;
    f.origin.y -= _dPadBacking.frame.origin.y;
    i.frame = f;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleRightMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_dPadBacking addSubview:i];

    // thumbPressed
    i = self.dPadThumbPressedImage;
    f = fBase;
    ins = (fBase.size.width - thumbSize) * 0.5;
    f = CGRectInset(f, ins, ins);
    f.origin.x -= _dPadBacking.frame.origin.x;
    f.origin.y -= _dPadBacking.frame.origin.y;
    i.frame = f;
    i.hidden = YES;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleRightMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_dPadBacking addSubview:i];
  }

  // buttons
  {

    CGRect fBase;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
      fBase = CGRectMake(width - 210, height / 2 - 120, 200, 200);
    } else {
      fBase = CGRectMake(width - 210, height * 0.65 - 120, 200, 200);
    }

    UIView *v = self.buttonBacking;

    // backing
    v.frame = fBase;
    v.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:v];

    float offset = 0.73f;
    float buttonSize = 160.0f;

    float offs = fBase.size.width * 0.5f * offset;
    float ins = (fBase.size.width - buttonSize) * 0.5f;

    i = self.buttonImagePunch;
    f = fBase;
    f = CGRectOffset(f, -offs, 0);
    f = CGRectInset(f, ins, ins);
    f.origin.x -= _buttonBacking.frame.origin.x;
    f.origin.y -= _buttonBacking.frame.origin.y;
    i.frame = f;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];

    i = self.buttonImagePunchPressed;
    i.frame = f;
    i.hidden = YES;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];

    i = self.buttonImageJump;
    f = fBase;
    f = CGRectOffset(f, 0, offs);
    f = CGRectInset(f, ins, ins);
    f.origin.x -= _buttonBacking.frame.origin.x;
    f.origin.y -= _buttonBacking.frame.origin.y;
    i.frame = f;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];

    i = self.buttonImageJumpPressed;
    i.frame = f;
    i.hidden = YES;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];

    i = self.buttonImageThrow;
    f = fBase;
    f = CGRectOffset(f, 0, -offs);
    f = CGRectInset(f, ins, ins);
    f.origin.x -= _buttonBacking.frame.origin.x;
    f.origin.y -= _buttonBacking.frame.origin.y;
    i.frame = f;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];

    i = self.buttonImageThrowPressed;
    i.frame = f;
    i.hidden = YES;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];

    i = self.buttonImageBomb;
    f = fBase;
    f = CGRectOffset(f, offs, 0);
    f = CGRectInset(f, ins, ins);
    f.origin.x -= _buttonBacking.frame.origin.x;
    f.origin.y -= _buttonBacking.frame.origin.y;
    i.frame = f;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];

    i = self.buttonImageBombPressed;
    i.frame = f;
    i.hidden = YES;
    i.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleBottomMargin;
    [_buttonBacking addSubview:i];
  }

  // options button
  b = [UIButton buttonWithType:UIButtonTypeCustom];

  if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
    b.frame = CGRectMake(width / 2 - (buttonWidth / 2), 10, buttonWidth,
                         buttonHeight);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin |
                         UIViewAutoresizingFlexibleLeftMargin;

  } else if (@available(iOS 11.0, *)) {

    b.frame = CGRectMake(
        (buttonWidth * 0.6 * 1.3) +
            UIApplication.sharedApplication.keyWindow.safeAreaInsets.left,
        5, buttonWidth * 0.6, buttonHeight * 0.6);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin;
  } else {
    b.frame = CGRectMake(buttonWidth * 0.6 * 1.3, 5, buttonWidth * 0.6,
                         buttonHeight * 0.6);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin;
  }

  [b addTarget:self
                action:@selector(showPrefs)
      forControlEvents:UIControlEventTouchUpInside];
  [b setBackgroundImage:[UIImage imageNamed:@"buttonOptions.png"]
               forState:UIControlStateNormal];
  [self.view addSubview:b];

  // leave button
  b = [UIButton buttonWithType:UIButtonTypeCustom];

  if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
    b.frame = CGRectMake(10, 10, buttonWidth, buttonHeight);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin;
  } else if (@available(iOS 11.0, *)) {

    b.frame = CGRectMake(
        UIApplication.sharedApplication.keyWindow.safeAreaInsets.left + 5, 5,
        buttonWidth * 0.6, buttonHeight * 0.6);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin;
  } else {
    b.frame = CGRectMake(5, 5, buttonWidth * 0.6, buttonHeight * 0.6);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin;
  }
  [b addTarget:self
                action:@selector(leave)
      forControlEvents:UIControlEventTouchUpInside];
  [b setBackgroundImage:[UIImage imageNamed:@"buttonLeave.png"]
               forState:UIControlStateNormal];
  [self.view addSubview:b];

  // start button
  b = [UIButton buttonWithType:UIButtonTypeCustom];
  if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
    b.frame = CGRectMake(width - buttonWidth * 1.0 - 10, 10, buttonWidth * 1.0,
                         buttonHeight * 1.0);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleLeftMargin |
                         UIViewAutoresizingFlexibleRightMargin;

  } else if (@available(iOS 11.0, *)) {

    b.frame = CGRectMake(
        (buttonWidth * 0.6 * 2.6) +
            UIApplication.sharedApplication.keyWindow.safeAreaInsets.left,
        5, buttonWidth * 0.6, buttonHeight * 0.6);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin;
  } else {
    b.frame = CGRectMake(buttonWidth * 0.6 * 2.6, 5, buttonWidth * 0.6,
                         buttonHeight * 0.6);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                         UIViewAutoresizingFlexibleRightMargin;
  }

  [b addTarget:self
                action:@selector(handleMenu)
      forControlEvents:UIControlEventTouchUpInside];

  [b setBackgroundImage:[UIImage imageNamed:@"buttonMenu.png"]
               forState:UIControlStateNormal];
  [self.view addSubview:b];

  // throw up our activity indicator if needed
  if (not _connected) {
    [self showActivityIndicator];
  }
}

- (void)showActivityIndicator {
  if (self.activityIndicator != nil) {
    return;
  }

  self.activityIndicator = [[[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge]
      autorelease];

  CGRect frame = CGRectMake(145, 160, 40, 40);
  frame.origin.x =
      round((self.view.bounds.size.width - frame.size.width) / 2.0);
  frame.origin.y =
      round((self.view.bounds.size.height - frame.size.height) / 2.0);
  _activityIndicator.frame = frame;
  _activityIndicator.tag = 1;
  self.activityIndicator.autoresizingMask =
      UIViewAutoresizingFlexibleLeftMargin |
      UIViewAutoresizingFlexibleRightMargin |
      UIViewAutoresizingFlexibleTopMargin |
      UIViewAutoresizingFlexibleBottomMargin;
  [self.view addSubview:_activityIndicator];
  [_activityIndicator startAnimating];
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
}

- (void)viewDidUnload {
  [super viewDidUnload];
  // Release any retained subviews of the main view.
  self.buttonBacking = nil;
  self.buttonImageJump = nil;
  self.buttonImageJumpPressed = nil;
  self.buttonImageThrow = nil;
  self.buttonImageThrowPressed = nil;
  self.buttonImagePunch = nil;
  self.buttonImagePunchPressed = nil;
  self.buttonImageBomb = nil;
  self.buttonImageBombPressed = nil;
  self.dPadBacking = nil;
  self.dPadThumbImage = nil;
  self.dPadThumbPressedImage = nil;
  self.dPadCenterImage = nil;
  self.bgImage = nil;
  self.activityIndicator = nil;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:
    (UIInterfaceOrientation)interfaceOrientationIn {
  // iPad works any which way.. iPhone only landscape
  if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
    return YES;
  } else {
    return (interfaceOrientationIn == UIInterfaceOrientationLandscapeLeft ||
            interfaceOrientationIn == UIInterfaceOrientationLandscapeRight);
  }
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];

  // Let the device go to sleep if its just in the browser
  [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.navigationController setNavigationBarHidden:YES animated:animated];

  // if we're in tilt mode, start measuring
  if (_tiltMode) {
    // put on the brakes
    _buttonStateV1 |= BS_REMOTE_STATE_HOLD_POSITION;
    _buttonStateV2 |= BS_REMOTE_STATE2_HOLD_POSITION;
    [self doStateChangeForced:NO];
  }
  // Keep the device awake as long as we're in the actual controller..
  [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];

  // ok, we can die now if need be
  _canDie = YES;
}

- (void)showPrefs {
  [[AppController sharedApp] showPrefsWithDelegate:self];
}

- (void)axisSnappingChanged:(NSNumber *)enabled {
  _axisSnapping = [enabled intValue];
}

- (void)tiltNeutralChangedToY:(float)y z:(float)z {
  _tiltNeutralY = y;
  _tiltNeutralZ = z;
}

- (void)controllerDPadSensitivityChanged:(float)value {
  _controllerDPadSensitivity = value;
}

- (void)tiltModeChanged:(NSNumber *)enabled {
  _tiltMode = [enabled intValue];

  // reset stuff so we don't continue along with the current joystick value...
  _dPadBaseX = 0;
  _dPadBaseY = DPAD_NEUTRAL_Y;

  // put on the brakes
  _buttonStateV1 |= BS_REMOTE_STATE_HOLD_POSITION;
  _buttonStateV2 |= BS_REMOTE_STATE2_HOLD_POSITION;
  [self doStateChangeForced:NO];
  [self updateDPadBase];
  [self setDPadX:0 andY:0 andPressed:NO andDirect:NO];
}

- (void)joystickFloatingChanged:(NSNumber *)enabled {
  _floating = [enabled intValue];

  // reset stuff so we don't continue along with the current joystick value...
  _dPadBaseX = 0;
  _dPadBaseY = DPAD_NEUTRAL_Y;
  [self setDPadX:0 andY:0 andPressed:NO andDirect:NO];
  [self updateDPadBase];
}

- (void)joystickSizeChanged:(float)value {
  _joystickSize = value;
  
  // Update the joystick size visually
  float thumbSize = 128 * _joystickSize;
  float centerSize = 256 * _joystickSize;
  
  CGRect fBase = self.dPadBacking.frame;
  CGRect f;
  float ins;
  
  // Update center image size
  UIImageView *i = self.dPadCenterImage;
  f = fBase;
  ins = (fBase.size.width - centerSize) * 0.5;
  f = CGRectInset(f, ins, ins);
  f.origin.x -= _dPadBacking.frame.origin.x;
  f.origin.y -= _dPadBacking.frame.origin.y;
  i.frame = f;
  
  // Update thumb image size
  i = self.dPadThumbImage;
  f = fBase;
  ins = (fBase.size.width - thumbSize) * 0.5;
  f = CGRectInset(f, ins, ins);
  f.origin.x -= _dPadBacking.frame.origin.x;
  f.origin.y -= _dPadBacking.frame.origin.y;
  i.frame = f;
  
  // Update pressed thumb image size
  i = self.dPadThumbPressedImage;
  f = fBase;
  ins = (fBase.size.width - thumbSize) * 0.5;
  f = CGRectInset(f, ins, ins);
  f.origin.x -= _dPadBacking.frame.origin.x;
  f.origin.y -= _dPadBacking.frame.origin.y;
  i.frame = f;
  
  // Save the new size to user defaults
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setFloat:value forKey:@"joystickSize"];
  [defaults synchronize];
  
  // Update the joystick position
  [self updateDPadBase];
}

- (void)leave {
  [self showActivityIndicator];

  _wantToLeave = YES;
  _leavingStartTime = CACurrentMediaTime();

  // shoot off a disconnect immediately.. (subsequent attempts will happen in
  // process())
  if (_id != -1) {
    UInt8 data[2] = {BS_REMOTE_MSG_DISCONNECT, _id};

    if (_haveV4) {
      send(_socket4, data, sizeof(data), 0);
    }
    if (_haveV6) {
      send(_socket6, data, sizeof(data), 0);
    }
  }
}

- (void)tryToDie {
  [self showActivityIndicator];

  // mark us as a zombie
  _wantToDie = YES;

  // shoot off a message to the server that we're going down so they can kill
  // our character (if they don't get it they'll have to wait for us to
  // time-out)
  if (_id != -1) {
    UInt8 data[2] = {BS_REMOTE_MSG_DISCONNECT, _id};

    if (_haveV4) {
      send(_socket4, data, sizeof(data), 0);
    }
    if (_haveV6) {
      send(_socket6, data, sizeof(data), 0);
    }
  }

  if (_cfSocket4) {
    CFSocketInvalidate(_cfSocket4);
    CFRelease(_cfSocket4);
    _cfSocket4 = NULL;
  }
  if (_cfSocket6) {
    CFSocketInvalidate(_cfSocket6);
    CFRelease(_cfSocket6);
    _cfSocket6 = NULL;
  }

  // kill our timers; they're holding refs to us..

  // we only kill the process timer if we're actually able to die.
  // (not waiting for our view-controller to finish coming up)
  // if we're waiting, we need the process timer to keep trying to die
  if (_canDie) {
    [_processTimer invalidate];
    self.processTimer = nil;
  }

  // finally, if we're able to kill our view controller yet, do so
  if (_canDie && !_dying) {
    // printf("POPPING VIEW CONTROLLER\n");
    [self.navigationController popViewControllerAnimated:YES];
    _dying = YES;
  }
}

#pragma mark -
#pragma mark Touch Event Handling

- (CGPoint)getPointInImageSpace:(UIView *)view forPoint:(CGPoint)p {
  CGRect f = view.frame;
  p.x -= f.origin.x;
  p.y -= f.origin.y;
  p.x /= f.size.width * 0.5;
  p.y /= f.size.height * 0.5;
  p.x -= 1.0;
  p.y -= 1.0;
  return p;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {

  for (UITouch *touch in touches) {

    // add these to our valid touches
    // the reason we keep our own list of touches instead of just using the
    // event's all-touches set is that I was getting touches-moved events for
    // touches that had already received touches-ended events.. this was
    // triggering extra button actions when touches ended.
    [self.validTouches addObject:touch];

    CGPoint pView = [touch locationInView:self.view];
    CGPoint pd = [self getPointInImageSpace:self.dPadBacking forPoint:pView];
    if (pd.x > -1.0 * DPAD_BUFFER and pd.x < 1.0 * DPAD_BUFFER and
        pd.y > -1.0 * DPAD_BUFFER and pd.y < 1.0 * DPAD_BUFFER) {

      _dPadTouch = touch;

      if (_tiltMode) {
        // if our finger's down, brakes are off
        _buttonStateV1 &= ~BS_REMOTE_STATE_HOLD_POSITION;
        _buttonStateV2 &= ~BS_REMOTE_STATE2_HOLD_POSITION;
      } else {
        // joystick mode
        // if this is a double-tap, we flip on hold-position
        // for the duration of this touch
        CFTimeInterval time = CACurrentMediaTime();
        _buttonStateV1 &= ~BS_REMOTE_STATE_HOLD_POSITION;
        _buttonStateV2 &= ~BS_REMOTE_STATE2_HOLD_POSITION;
        [self doStateChangeForced:NO];

        _lastDPadTouchTime = time;
        _lastDPadTouchPosX = 0.0;
        _lastDPadTouchPosY = 0.0;
        _dPadHasMoved = NO;

        if (_floating) {
          // we always move the d-pad-base to where the start of the touch is
          _dPadBaseX = pd.x;
          _dPadBaseY = pd.y;

          // we dont move the dpad base until there's movement..
          // (that way taps look less odd visually)
          _needToUpdateDPadBase = YES;
        }

        [self setDPadX:pd.x andY:pd.y andPressed:YES andDirect:NO];
      }
    }
  }

  // lets make sure our set of valid touches doesn't contain any that aren't in
  // the list of all touches.. (not sure if this could happen but might as well
  // be safe)
  [self.validTouches intersectSet:[event allTouches]];

  [self updateButtonsForTouches];
}

- (void)updateDPadBase {
  float x = _dPadBaseX;
  float y = _dPadBaseY;
  CGRect fBack = self.dPadBacking.frame;
  fBack.origin.x = 0;
  fBack.origin.y = 0;
  CGRect f = self.dPadCenterImage.frame;
  f.origin = fBack.origin;
  f.origin.x += fBack.size.width / 2.0 - f.size.width / 2.0;
  f.origin.y += fBack.size.height / 2.0 - f.size.height / 2.0;
  f.origin.x += x * fBack.size.width / 2.0;
  f.origin.y += y * fBack.size.width / 2.0;
  self.dPadCenterImage.frame = f;
}

- (void)handleDpadInput:(float)xValue yValue:(float)yValue {
    // Handle dpad input
    [self handleJoystickInput:xValue yValue:yValue];
}

- (void)handleButtonA:(BOOL)pressed {
    if (pressed) {
        [self handleJumpPress];
    } else {
        [self handleJumpRelease];
    }
}

- (void)handleButtonB:(BOOL)pressed {
    if (pressed) {
        [self handleBombPress];
    } else {
        [self handleBombRelease];
    }
}

- (void)handleButtonX:(BOOL)pressed {
    if (pressed) {
        [self handlePunchPress];
    } else {
        [self handlePunchRelease];
    }
}

- (void)handleButtonY:(BOOL)pressed {
    if (pressed) {
        [self handleThrowPress];
    } else {
        [self handleThrowRelease];
    }
}

- (void)handleLeftShoulder:(BOOL)pressed {
    if (pressed) {
        [self handleRun1Press];
    } else {
        [self handleRun1Release];
    }
}

- (void)handleRightShoulder:(BOOL)pressed {
    if (pressed) {
        [self handleRun2Press];
    } else {
        [self handleRun2Release];
    }
}

- (void)handleLeftTrigger:(BOOL)pressed {
    if (pressed) {
        [self handleRun1Press];
    } else {
        [self handleRun1Release];
    }
}

- (void)handleRightTrigger:(BOOL)pressed {
    if (pressed) {
        [self handleRun2Press];
    } else {
        [self handleRun2Release];
    }
}

- (void)handleLeftThumbstick:(float)xValue yValue:(float)yValue {
    [self handleJoystickInput:xValue yValue:yValue];
}

- (void)handleAccelerometerData:(CMAccelerometerData *)accelerometerData {
    // Handle accelerometer data
    float x = accelerometerData.acceleration.x;
    float y = accelerometerData.acceleration.y;
    float z = accelerometerData.acceleration.z;
    
    // Convert accelerometer data to joystick input
    float joystickX = x * 2.0f; // Scale as needed
    float joystickY = y * 2.0f; // Scale as needed
    
    [self handleJoystickInput:joystickX yValue:joystickY];
}

@end
