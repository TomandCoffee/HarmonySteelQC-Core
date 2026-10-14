import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'SteelQC', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'SteelQC', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'SteelQC', 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'SteelQC', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'SteelQC', 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'SteelQC', 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'SteelQC', 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'SteelQC', 'onBackground');
  }
}
