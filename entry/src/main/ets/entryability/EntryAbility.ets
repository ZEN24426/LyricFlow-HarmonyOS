import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 先加载页面。Stage 窗口的背景色必须在 loadContent 生效后设置，
    // 否则某些 HarmonyOS 7 设备会抛出 1300002，导致启动时闪退。
    windowStage.loadContent('pages/Index').then(() => {
      let mainWindow: window.Window;
      try {
        mainWindow = windowStage.getMainWindowSync();
      } catch (error) {
        console.error(`getMainWindowSync failed: ${String(error)}`);
        return;
      }

      // 系统栏和应用背景保持一致，但窗口装饰失败不能影响页面正常运行。
      try {
        mainWindow.setWindowBackgroundColor('#F6F8FB');
      } catch (error) {
        console.error(`setWindowBackgroundColor failed (non-fatal): ${String(error)}`);
      }
      try {
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#F6F8FB',
          navigationBarColor: '#F6F8FB',
          statusBarContentColor: '#172B4D',
          navigationBarContentColor: '#172B4D'
        }).catch((err: BusinessError) => {
          console.error(`setWindowSystemBarProperties failed (non-fatal): ${JSON.stringify(err)}`);
        });
      } catch (error) {
        console.error(`setWindowSystemBarProperties threw (non-fatal): ${String(error)}`);
      }
    }).catch((err: BusinessError) => {
      console.error(`loadContent failed: ${JSON.stringify(err)}`);
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
