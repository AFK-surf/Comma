#import "CommaPerfMetrics.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach/thread_act.h>
#include <mach/thread_info.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/utsname.h>

@implementation CommaPerfThreadSample

- (instancetype)initWithSummary:(NSString *)summary
                    hottestName:(NSString *)hottestName
                hottestThreadID:(uint64_t)hottestThreadID
                 hottestPercent:(double)hottestPercent {
  if ((self = [super init])) {
    _summary = [summary copy];
    _hottestName = [hottestName copy];
    _hottestThreadID = hottestThreadID;
    _hottestPercent = hottestPercent;
  }
  return self;
}

@end

@implementation CommaPerfThreadTracker {
  NSMutableDictionary<NSNumber *, NSNumber *> *_previous;
  BOOL _primed;
}

- (instancetype)init {
  if ((self = [super init])) {
    _previous = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)reset {
  [_previous removeAllObjects];
  _primed = NO;
}

- (CommaPerfThreadSample *)sampleOverSpanMs:(double)spanMs {
  double denom = spanMs > 1.0 ? spanMs : 1.0;
  NSMutableDictionary<NSNumber *, NSNumber *> *current = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSNumber *> *byLabel = [NSMutableDictionary dictionary];
  NSString *hottestName = @"";
  uint64_t hottestTid = 0;
  double hottestDelta = 0.0;

  BOOL isMainCaller = pthread_main_np() != 0;
  pthread_t selfThread = pthread_self();

  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
    return [[CommaPerfThreadSample alloc] initWithSummary:@"" hottestName:@"" hottestThreadID:0 hottestPercent:0.0];
  }

  for (mach_msg_type_number_t i = 0; i < count; i++) {
    thread_identifier_info_data_t ident = {0};
    mach_msg_type_number_t identCount = THREAD_IDENTIFIER_INFO_COUNT;
    thread_basic_info_data_t basic = {0};
    mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
    if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &identCount) == KERN_SUCCESS &&
        thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) == KERN_SUCCESS) {
      double ms = basic.user_time.seconds * 1000.0 + basic.user_time.microseconds / 1000.0 +
                  basic.system_time.seconds * 1000.0 + basic.system_time.microseconds / 1000.0;
      NSNumber *key = @(ident.thread_id);
      current[key] = @(ms);
      if (_primed) {
        NSNumber *prev = _previous[key];
        double delta = prev ? (ms >= prev.doubleValue ? ms - prev.doubleValue : 0.0) : ms;
        char name[64] = "";
        pthread_t pt = pthread_from_mach_thread_np(threads[i]);
        if (pt) pthread_getname_np(pt, name, sizeof name);
        NSString *label;
        if (name[0]) {
          label = @(name);
        } else if (isMainCaller && pt == selfThread) {
          label = @"main";
        } else {
          label = ident.dispatch_qaddr ? @"gcd" : @"?";
        }
        byLabel[label] = @(byLabel[label].doubleValue + delta);
        if (delta > hottestDelta) {
          hottestDelta = delta;
          hottestTid = ident.thread_id;
          hottestName = label;
        }
      }
    }
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));

  _previous = current;
  if (!_primed) {
    _primed = YES;
    return [[CommaPerfThreadSample alloc] initWithSummary:@"" hottestName:@"" hottestThreadID:0 hottestPercent:0.0];
  }

  NSArray<NSString *> *sorted = [byLabel keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
    return [b compare:a];
  }];
  NSMutableString *line = [NSMutableString string];
  for (NSUInteger i = 0; i < MIN(sorted.count, (NSUInteger)8); i++) {
    double pct = byLabel[sorted[i]].doubleValue * 100.0 / denom;
    if (pct < 0.5) break;
    NSString *sanitized = [sorted[i] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    [line appendFormat:@" %@=%.0f%%", sanitized, pct];
  }
  if (line.length == 0) {
    [line appendString:@" (all <0.5%)"];
  }
  double hottestPct = hottestDelta * 100.0 / denom;
  return [[CommaPerfThreadSample alloc] initWithSummary:line
                                            hottestName:[hottestName stringByReplacingOccurrencesOfString:@" " withString:@"_"]
                                        hottestThreadID:hottestTid
                                         hottestPercent:hottestPct];
}

@end

double CommaPerfProcessCPUMs(void) {
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) return -1.0;
  return (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000.0 +
         (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000.0;
}

double CommaPerfMemoryBytes(void) {
  task_vm_info_data_t info = {0};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0.0;
  return (double)info.phys_footprint;
}

CommaPerfPowerSnap CommaPerfReadPower(void) {
  CommaPerfPowerSnap snap = {0};
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) == 0) {
    snap.valid = YES;
    snap.userMs = usage.ru_utime.tv_sec * 1000.0 + usage.ru_utime.tv_usec / 1000.0;
    snap.sysMs = usage.ru_stime.tv_sec * 1000.0 + usage.ru_stime.tv_usec / 1000.0;
  }
  task_power_info_v2_data_t pi2 = {0};
  mach_msg_type_number_t cnt2 = TASK_POWER_INFO_V2_COUNT;
  if (task_info(mach_task_self(), TASK_POWER_INFO_V2, (task_info_t)&pi2, &cnt2) == KERN_SUCCESS) {
    snap.valid = YES;
    snap.hasPowerInfo = YES;
    snap.hasPowerV2 = YES;
    snap.idleWakeups = pi2.cpu_energy.task_platform_idle_wakeups;
    snap.intrWakeups = pi2.cpu_energy.task_interrupt_wakeups;
    snap.timerBin1 = pi2.cpu_energy.task_timer_wakeups_bin_1;
    snap.timerBin2 = pi2.cpu_energy.task_timer_wakeups_bin_2;
    snap.gpuNs = pi2.gpu_energy.task_gpu_utilisation;
#if defined(__arm__) || defined(__arm64__)
    snap.hasEnergy = YES;
    snap.energyNj = pi2.task_energy;
#endif
  } else {
    task_power_info_data_t pi1 = {0};
    mach_msg_type_number_t cnt1 = TASK_POWER_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_POWER_INFO, (task_info_t)&pi1, &cnt1) == KERN_SUCCESS) {
      snap.valid = YES;
      snap.hasPowerInfo = YES;
      snap.idleWakeups = pi1.task_platform_idle_wakeups;
      snap.intrWakeups = pi1.task_interrupt_wakeups;
      snap.timerBin1 = pi1.task_timer_wakeups_bin_1;
      snap.timerBin2 = pi1.task_timer_wakeups_bin_2;
    }
  }
  return snap;
}

NSString *CommaPerfMachineIdentifier(void) {
  struct utsname u;
  if (uname(&u) != 0) return @"unknown";
  return [NSString stringWithUTF8String:u.machine] ?: @"unknown";
}

NSString *CommaPerfBinaryUUID(void) {
  const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
  if (!header) return @"?";
  const struct load_command *lc = (const struct load_command *)(header + 1);
  for (uint32_t i = 0; i < header->ncmds; i++) {
    if (lc->cmd == LC_UUID) {
      return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)lc)->uuid].UUIDString;
    }
    lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
  }
  return @"?";
}

#if defined(__arm64__)
static void formatFrame(uintptr_t pc, char *out, size_t n) {
  Dl_info info;
  uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
  if (!dladdr((const void *)pc, &info) || !info.dli_fbase) {
    snprintf(out, n, " ?0x%lx", (unsigned long)pc);
  } else if ((uintptr_t)info.dli_fbase == base) {
    snprintf(out, n, " +0x%lx", (unsigned long)(pc - base));
  } else {
    const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
    const char *imageName = image ? image + 1 : (info.dli_fname ?: "?");
    snprintf(out, n, " %s:%s+%lu", imageName, info.dli_sname ?: "?",
             (unsigned long)(pc - (uintptr_t)(info.dli_saddr ?: info.dli_fbase)));
  }
}
#endif

NSString *_Nullable CommaPerfSampleThreadStack(uint64_t threadID, int sampleIndex) {
#if defined(__arm64__)
  enum { kMaxFrames = 48 };
  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return nil;

  uintptr_t frames[kMaxFrames];
  int depth = 0;
  BOOL captured = NO;
  char name[64] = "";
  thread_act_t selfPort = mach_thread_self();

  for (mach_msg_type_number_t i = 0; i < count; i++) {
    if (threads[i] == selfPort) continue;
    thread_identifier_info_data_t ident = {0};
    mach_msg_type_number_t identCount = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &identCount) != KERN_SUCCESS ||
        ident.thread_id != threadID) {
      continue;
    }
    // No heap allocation or dyld locks while the target thread is suspended.
    if (thread_suspend(threads[i]) == KERN_SUCCESS) {
      arm_thread_state64_t st;
      mach_msg_type_number_t stCount = ARM_THREAD_STATE64_COUNT;
      if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &stCount) == KERN_SUCCESS) {
        frames[depth++] = (uintptr_t)arm_thread_state64_get_pc(st);
        frames[depth++] = (uintptr_t)arm_thread_state64_get_lr(st);
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
        while (fp && (fp & 7) == 0 && depth < kMaxFrames) {
          uintptr_t rec[2];
          vm_size_t got = 0;
          if (vm_read_overwrite(mach_task_self(), fp, sizeof rec, (vm_address_t)rec, &got) != KERN_SUCCESS ||
              got != sizeof rec) {
            break;
          }
          if (!rec[1]) break;
          frames[depth++] = rec[1] & 0x0000000fffffffffULL;
          if (rec[0] <= fp) break;
          fp = rec[0];
        }
        captured = YES;
      }
      thread_resume(threads[i]);
    }
    pthread_t pt = pthread_from_mach_thread_np(threads[i]);
    if (pt) pthread_getname_np(pt, name, sizeof name);
    break;
  }

  mach_port_deallocate(mach_task_self(), selfPort);
  for (mach_msg_type_number_t i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), threads[i]);
  vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));

  if (!captured || depth == 0) return nil;
  char line[4096];
  int at = snprintf(line, sizeof line, "hot stack: #%d thread %llu%s%s%s",
                    sampleIndex, (unsigned long long)threadID,
                    name[0] ? " (" : "", name[0] ? name : "", name[0] ? ")" : "");
  for (int f = 0; f < depth && at > 0 && at < (int)sizeof line - 1; f++) {
    char one[160];
    formatFrame(frames[f], one, sizeof one);
    at += snprintf(line + at, sizeof line - (size_t)at, "%s", one);
  }
  return [NSString stringWithUTF8String:line];
#else
  (void)threadID;
  (void)sampleIndex;
  return nil;
#endif
}
