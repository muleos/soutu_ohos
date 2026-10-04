import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { EmitterUtil } from '../utiles/EmitterUtil'
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';

const DOMAIN = 0x0000;
const DEFAULT_HOME_URL: string = 'https://soutushenqi.com/image/feature';
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // WebView 内核预热 + 主页预连接：冷启动提前建立 TCP/TLS，减少首屏与重复加载耗时。
    // 失败仅降级为普通加载，不阻塞启动
    try {
      webview.WebviewController.initializeWebEngine();
      const pref = preferences.getPreferencesSync(this.context, { name: 'app_config' });
      const homeUrl: string = String(pref.getSync('homepage_url', DEFAULT_HOME_URL)) || DEFAULT_HOME_URL;
      webview.WebviewController.prepareForPageLoad(homeUrl, true, 2);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'webview preheat failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    windowStage.getMainWindow((err, data) => {
      if (err.code) {
        console.error('获取失败' + JSON.stringify(err));
        return;
      }
      console.info('获取主窗口的实例：' + JSON.stringify(data));
      globalThis.windowClass = data // 赋值给全局变量windowClass
      // 设置全屏显示
      //globalThis.windowClass.setWindowLayoutFullScreen(true)
      // 隐藏状态栏显示
      //globalThis.windowClass.setWindowSystemBarEnable(['navigation'])
    });
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色切换：通知页面重设系统栏背景
    EmitterUtil.post('stq_color_mode_changed', newConfig.colorMode);
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}