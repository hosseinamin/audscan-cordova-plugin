//
//  NativeAccessApi.m
//  AUDScan
//
//  Created by Hossein Amin on 5/22/17.
//
//

#import "NativeAccessApi.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

@interface NAAFinishCallbackData : NSObject

@property (nonatomic) AVSpeechSynthesizer *synthesizer;
@property (nonatomic) AVSpeechUtterance *utterance;
@property (nonatomic) NSString *callbackId;

+ (NAAFinishCallbackData*)dataWithSynthesizer:(AVSpeechSynthesizer*)synthesizer utterance:(AVSpeechUtterance*)utterance callbackId:(NSString*)callbackId;

@end

@implementation NAAFinishCallbackData

+ (NAAFinishCallbackData*)dataWithSynthesizer:(AVSpeechSynthesizer*)synthesizer utterance:(AVSpeechUtterance*)utterance callbackId:(NSString*)callbackId {
    NAAFinishCallbackData *data = [[NAAFinishCallbackData alloc] init];
    data.utterance = utterance;
    data.synthesizer = synthesizer;
    data.callbackId = callbackId;
    return data;
}

@end

@interface NativeAccessApi () <AVSpeechSynthesizerDelegate>

@end

@implementation NativeAccessApi {
    NSMutableDictionary *_pointers;
    NSMutableArray *_finish_callbacks;
    BOOL _isSoftKeyboardVisible;
    id _keyCommandBlock;
    NSMutableDictionary *_KeyInputMap;
    NSMutableDictionary *_KeyInputRevMap;
    NSMutableArray *_keyCommands;
}

- (void)pluginInitialize {
    [super pluginInitialize];
    _pointers = [[NSMutableDictionary alloc] init];
    _finish_callbacks = [[NSMutableArray alloc] init];
    _isSoftKeyboardVisible = NO;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [self keyboardInitialize];
    _KeyInputMap = [@{
                      @"UP": UIKeyInputUpArrow,
                      @"RIGHT": UIKeyInputRightArrow,
                      @"DOWN": UIKeyInputDownArrow,
                      @"LEFT": UIKeyInputLeftArrow,
                      @"RETURN": @"\r",
                      @"SPACE": @" "
                      } mutableCopy];
    _KeyInputRevMap = [NSMutableDictionary new];
    for(NSString *key in [_KeyInputMap allKeys]) {
        [_KeyInputRevMap setObject:key forKey:[_KeyInputMap objectForKey:key]];
    }
}

- (void)onReset {
    [self keyboardReset];
}

BOOL mvc_canBecomeFirstResponder(id self, SEL __cmd) {
    return YES;
}

void mvc_onKeyCommandDummy(id self, SEL __cmd, UIKeyCommand *keyCommand) {
}

- (void)keyboardInitialize {
    // overwrite few viewcontroller's methods
    //NSString *vc_cls_str = NSStringFromClass([self.viewController class]);
    NativeAccessApi *_self = self;
    Class vc_class = [self.viewController class];
    BOOL result;
    result = class_addMethod(vc_class, NSSelectorFromString(@"canBecomeFirstResponder"), (IMP)mvc_canBecomeFirstResponder, "B@:");
    if(!result) {
        NSLog(@"Could not bind canBecomeFirstResponder to MainViewController");
    }
    _keyCommandBlock = ^(id _mvc, UIKeyCommand *keyCommand) {
        [_self onKeyCommand:keyCommand];
    };
    IMP keyCommandIMP = imp_implementationWithBlock(_keyCommandBlock);
    result = class_addMethod(vc_class, NSSelectorFromString(@"_onKeyCommand:"), keyCommandIMP, "v@:@");
    if(!result) {
        NSLog(@"Could not bind didKeyCommand: to MainViewController");
    }
    [self keyboardReset];
}

- (void)keyboardDestroy {
    BOOL result;
    if(self.viewController != nil) {
        [self keyboardReset];
        Class vc_class = [self.viewController class];
        result = class_addMethod(vc_class, NSSelectorFromString(@"_onKeyCommand:"), (IMP)mvc_onKeyCommandDummy, "v@:@");
        if(!result) {
            NSLog(@"Could not bind didKeyCommand: to MainViewController");
        }
    }
}

- (void)keyboardReset {
    if(_keyCommands != nil) {
        for(UIKeyCommand *cmd in _keyCommands) {
            [self.viewController removeKeyCommand:cmd];
        }
    }
    _keyCommands = [NSMutableArray new];
}

- (void)onKeyCommand:(UIKeyCommand*)keyCommand {
    NSString *input = [_KeyInputRevMap objectForKey:keyCommand.input];
    if(input == nil) {
        input = keyCommand.input;
    }
    NSError *error = nil;
    NSDictionary *detail = @{ @"input": input };
    NSString *detailjson = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:detail options:0 error:&error] encoding:NSUTF8StringEncoding];
    if(error != nil) {
        NSLog(@"onKeyCommand error, Could not serialize detail, %@", [error localizedDescription]);
    }
    NSString *jsScript = [NSString stringWithFormat:@"document.dispatchEvent(new CustomEvent(\"x-keycommand\",{detail:%@}));", detailjson];
    [self.webViewEngine evaluateJavaScript:jsScript completionHandler:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification
{
    NSDictionary* userInfo = [notification userInfo];
    CGRect keyboardFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboard = [self.viewController.view convertRect:keyboardFrame fromView:self.viewController.view.window];
    CGFloat height = self.viewController.view.frame.size.height;
    @synchronized (self) {
        _isSoftKeyboardVisible = (keyboard.origin.y + keyboard.size.height) <= height;
    }
}

- (void)keyboardWillHide:(NSNotification *)notification
{
    @synchronized (self) {
        _isSoftKeyboardVisible = NO;
    }
}

- (void)dispose {
    [super dispose];
    _pointers = nil;
    _finish_callbacks = nil;
    [self keyboardDestroy];
}

+ (NSString*)mkNewKeyForDict:(NSMutableDictionary*)dict {
    NSString *key;
    NSInteger trylen = 5;
    do {
        if(trylen == 0) {
            [[NSException exceptionWithName:@"TRYLEN EXCEED" reason:@"try length for new key exceeded" userInfo:nil] raise];
            break;
        }
        key = [[NSProcessInfo processInfo] globallyUniqueString];
        trylen -= 1;
    } while([dict objectForKey:key] != nil);
    return key;
}

- (id)pointerObjectForKey:(NSString*)key excepting:(Class)cls canBeNull:(Boolean)canBeNull error:(NSString**)error {
    id ptr;
    @synchronized (self) {
        ptr = [_pointers objectForKey:key];
    }
    if(ptr == nil) {
        *error = [NSString stringWithFormat:@"Excepting object of type %@ is nil", NSStringFromClass(cls)];
        return nil;
    }
    if(![ptr isKindOfClass:cls]) {
        *error = [NSString stringWithFormat:@"Excepting object of type %@ but %@ is given", NSStringFromClass(cls), NSStringFromClass([ptr class])];
        return nil;
    }
    return ptr;
}

- (void)add_key_command:(CDVInvokedUrlCommand*)command {
    NSString *arg1 = [command.arguments objectAtIndex:0];
    NSString *input = [_KeyInputMap objectForKey:arg1];
    if(input == nil) {
        input = arg1;
    }
    NSString *arg2 = nil;
    if([command.arguments count] > 1)
        arg2 = [command.arguments objectAtIndex:1];
    if(arg2 == nil || ![arg2 isKindOfClass:[NSString class]])
        arg2 = @"";
    UIKeyCommand *keyCommand = [UIKeyCommand keyCommandWithInput:input modifierFlags:0 action:NSSelectorFromString(@"_onKeyCommand:") discoverabilityTitle:arg2];
    [_keyCommands addObject:keyCommand];
    [self.viewController addKeyCommand:keyCommand];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)remove_key_command:(CDVInvokedUrlCommand*)command {
    NSString *arg1 = [command.arguments objectAtIndex:0];
    NSString *input = [_KeyInputMap objectForKey:arg1];
    if(input == nil) {
        input = arg1;
    }
    for(UIKeyCommand *aKeyCommand in _keyCommands) {
        if([aKeyCommand.input isEqualToString:input]) {
            [self.viewController removeKeyCommand:aKeyCommand];
        }
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)request_audio_record_permission:(CDVInvokedUrlCommand*)command {
  [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
      [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:granted] callbackId:command.callbackId];
    }];
}

- (void)has_synthesizer:(CDVInvokedUrlCommand*)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:YES] callbackId:command.callbackId];
}
- (void)has_audio_device:(CDVInvokedUrlCommand*)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:YES] callbackId:command.callbackId];
}

- (void)is_software_keyboard_visible:(CDVInvokedUrlCommand*)command {
    bool value;
    @synchronized (self) {
        value = _isSoftKeyboardVisible;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:value] callbackId:command.callbackId];
}

- (void)get_voices:(CDVInvokedUrlCommand*)command {
    NSMutableArray *voices = [NSMutableArray new];
    for(AVSpeechSynthesisVoice *voice in [AVSpeechSynthesisVoice speechVoices]) {
        [voices addObject:@{
                            @"id": voice.identifier,
                            @"label": voice.name
                            }];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:voices] callbackId:command.callbackId];
}

- (void)init_synthesizer:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        AVSpeechSynthesizer *speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
        speechSynthesizer.delegate = self;
        NSString *key;
        @synchronized (self) {
            key = [NativeAccessApi mkNewKeyForDict:_pointers];
            [_pointers setObject:speechSynthesizer forKey:key];
        }
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:key] callbackId:command.callbackId];
    });
}
- (void)init_utterance:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *speech = [command.arguments objectAtIndex:0];
        AVSpeechUtterance *speechUtterance = [[AVSpeechUtterance alloc] initWithString:speech];
        
        NSDictionary *options = command.arguments.count > 1 ?
        [command.arguments objectAtIndex:1] : nil;
        if([options isKindOfClass:[NSDictionary class]]) {
            NSString *voiceId = [options objectForKey:@"voiceId"];
            if([voiceId isKindOfClass:[NSString class]]) {
                AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithIdentifier:voiceId];
                if(voice != nil) {
                    speechUtterance.voice = voice;
                }
            }
            NSNumber *num;
            
            num = [options objectForKey:@"volume"];
            if([num isKindOfClass:[NSNumber class]]) {
                speechUtterance.volume = [num floatValue];
            }
            
            num = [options objectForKey:@"pitch"];
            if([num isKindOfClass:[NSNumber class]]) {
                speechUtterance.pitchMultiplier = [num floatValue];
            }
            
            NSString *rate = [options objectForKey:@"rate"];
            num = [options objectForKey:@"rateMul"];
            if([rate isKindOfClass:[NSString class]] ||
               [num isKindOfClass:[NSNumber class]]) {
                float rateVal = 1.0f;
                if([rate isEqualToString:@"default"]) {
                    rateVal = AVSpeechUtteranceDefaultSpeechRate;
                } else if([rate isEqualToString:@"min"]) {
                    rateVal = AVSpeechUtteranceMinimumSpeechRate;
                } else if([rate isEqualToString:@"max"]) {
                    rateVal = AVSpeechUtteranceMaximumSpeechRate;
                }
                if([num isKindOfClass:[NSNumber class]])
                    rateVal *= [num floatValue];
                speechUtterance.rate = rateVal;
            }
            
            num = [options objectForKey:@"delay"];
            if([num isKindOfClass:[NSNumber class]]) {
                speechUtterance.preUtteranceDelay = (NSTimeInterval)[num longValue] / 1000.0;
            }
        }
        
        NSString *key;
        @synchronized (self) {
            key = [NativeAccessApi mkNewKeyForDict:_pointers];
            [_pointers setObject:speechUtterance forKey:key];
        }
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:key] callbackId:command.callbackId];
    });
}
- (void)release_synthesizer:(CDVInvokedUrlCommand*)command {
    @synchronized (self) {
        [_pointers removeObjectForKey:[command.arguments objectAtIndex:0]];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}
- (void)release_utterance:(CDVInvokedUrlCommand*)command {
    @synchronized (self) {
        [_pointers removeObjectForKey:[command.arguments objectAtIndex:0]];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}
- (void)speak_utterance:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *synKey = [command.arguments objectAtIndex:0];
        NSString *uttKey = [command.arguments objectAtIndex:1];
        NSDictionary *opts = [command.arguments count] > 2 ?
          [command.arguments objectAtIndex:2] : nil;
        if(opts == nil)
          opts = [NSDictionary new];
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSNumber *override_to_speaker = [opts objectForKey:@"override_to_speaker"];
        NSError *error = nil;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
        if(error != nil) {
          NSLog(@"speak_utterance s01, %@", error);
          return [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"init failure!"] callbackId:command.callbackId];
        }
        if(override_to_speaker != nil && [override_to_speaker boolValue]) {
          [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                                     error:&error];
          if(error != nil) {
            return [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"override to speaker failed!"] callbackId:command.callbackId];
          }
        } else {
          [session overrideOutputAudioPort:AVAudioSessionPortOverrideNone
                                     error:&error];
          if(error != nil) {
            return [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"override to speaker failed!"] callbackId:command.callbackId];
          }
        }
        // set active
        [session setActive:YES error:&error];
        if(error != nil) {
            NSLog(@"speak_utterance s02, %@", error);
            return [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"init failure!"] callbackId:command.callbackId];
        }
        CDVPluginResult *result;
        NSString *error_msg = nil;
        AVSpeechSynthesizer *speechSynthesizer = [self pointerObjectForKey:synKey excepting:[AVSpeechSynthesizer class] canBeNull:NO error:&error_msg];
        AVSpeechUtterance *speechUtterance = [self pointerObjectForKey:uttKey excepting:[AVSpeechUtterance class] canBeNull:NO error:&error_msg];
        if(speechSynthesizer == nil || speechUtterance == nil) {
          result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error_msg];
        } else {
          [speechSynthesizer speakUtterance:speechUtterance];
          result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        }
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
      });
}
- (void)stop_speaking:(CDVInvokedUrlCommand*)command {
    NSString *synKey = [command.arguments objectAtIndex:0];
    CDVPluginResult *result;
    NSString *error = nil;
    AVSpeechSynthesizer *speechSynthesizer = [self pointerObjectForKey:synKey excepting:[AVSpeechSynthesizer class] canBeNull:NO error:&error];
    if(speechSynthesizer == nil) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error];
    } else {
        [speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}
- (void)speak_finish:(CDVInvokedUrlCommand*)command {
    NSString *synKey = [command.arguments objectAtIndex:0];
    NSString *uttKey = [command.arguments objectAtIndex:1];
    NSString *error = nil;
    AVSpeechSynthesizer *speechSynthesizer = [self pointerObjectForKey:synKey excepting:[AVSpeechSynthesizer class] canBeNull:NO error:&error];
    AVSpeechUtterance *speechUtterance = [self pointerObjectForKey:uttKey excepting:[AVSpeechUtterance class] canBeNull:NO error:&error];
    if(speechSynthesizer == nil || speechUtterance == nil) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error] callbackId:command.callbackId];
    } else {
        [_finish_callbacks addObject:[NAAFinishCallbackData dataWithSynthesizer:speechSynthesizer utterance:speechUtterance callbackId:command.callbackId]];
    }
}

- (void)applyFinishFor:(AVSpeechSynthesizer*)synthesizer utterance:(AVSpeechUtterance*)utterance {
    for (NSUInteger i = 0; i < [_finish_callbacks count]; ) {
        NAAFinishCallbackData *data = [_finish_callbacks objectAtIndex:i];
        if(data.synthesizer == synthesizer && data.utterance == utterance) {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:data.callbackId];
            [_finish_callbacks removeObjectAtIndex:i];
        } else {
            i++;
        }
    }
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    [self applyFinishFor:synthesizer utterance:utterance];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    [self applyFinishFor:synthesizer utterance:utterance];
}

@end


