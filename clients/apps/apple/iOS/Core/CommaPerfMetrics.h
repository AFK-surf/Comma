#import <Foundation/Foundation.h>
#import <stdbool.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct CommaPerfPowerSnap {
  bool valid;
  double userMs;
  double sysMs;
  bool hasPowerInfo;
  bool hasPowerV2;
  uint64_t idleWakeups;
  uint64_t intrWakeups;
  uint64_t timerBin1;
  uint64_t timerBin2;
  uint64_t gpuNs;
  bool hasEnergy;
  uint64_t energyNj;
} CommaPerfPowerSnap;

@interface CommaPerfThreadSample : NSObject
@property(nonatomic, readonly, copy) NSString *summary;
@property(nonatomic, readonly, copy) NSString *hottestName;
@property(nonatomic, readonly) uint64_t hottestThreadID;
@property(nonatomic, readonly) double hottestPercent;
@end

@interface CommaPerfThreadTracker : NSObject
- (CommaPerfThreadSample *)sampleOverSpanMs:(double)spanMs;
- (void)reset;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Total process CPU time (user + system) across all threads, in milliseconds (-1 on error).
double CommaPerfProcessCPUMs(void);

/// Current process physical memory footprint (`task_vm_info.phys_footprint`), in bytes.
double CommaPerfMemoryBytes(void);

/// Reads process user/sys CPU, idle/interrupt/timer wakeups, GPU time, and ARM energy counters.
CommaPerfPowerSnap CommaPerfReadPower(void);

/// Hardware model identifier from `uname` (for example, `iPhone17,2`).
NSString *CommaPerfMachineIdentifier(void);

/// Main executable Mach-O `LC_UUID` string, for `atos` symbolication.
NSString *CommaPerfBinaryUUID(void);

/// Captures one arm64 backtrace of the thread with `threadID` (never suspends the calling thread).
/// Returns nil if the thread is gone, is the calling thread, or on non-arm64 architectures.
NSString *_Nullable CommaPerfSampleThreadStack(uint64_t threadID, int sampleIndex);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
