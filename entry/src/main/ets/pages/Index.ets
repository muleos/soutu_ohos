import { webview } from '@kit.ArkWeb';
import { promptAction, window, display, mediaquery } from '@kit.ArkUI';
import { common, Want, OpenLinkOptions } from '@kit.AbilityKit';
import {
  saveHomeUrl,
  getHomeUrl,
  saveUserAgent,
  getUserAgent,
  saveLSRefresh,
  getLSRefresh,
  saveIshidebar,
  getIshidebar,
  getIshidestatus,
  saveIshidestatus,
  getUserAgentType,
  saveUserAgentType,
  getIsfull,
  saveIsfull,
  getSlidenum,
  saveSlidenum,
  saveWebDarkMode,
  getWebDarkMode,
  saveWebCookie,
  getWebCookie,
  saveBottomLift,
  getBottomLift
} from '../model/StorageService';
import { DownloadConfirmDialog } from '../component/DownloadConfirmDialog'
import { IAbstractDownloadHandler } from '../delegate/IWebDownloadFile'
import { WebDownloadFileHelper } from '../delegate/WebDownloadFileImpl'
import { EmitterUtil } from '../utiles/EmitterUtil'
import { WEB_CHROME_SCRIPT } from '../utiles/WebChromeScript'
import { WebImageSaver } from '../services/WebImageSaver'
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

enum ScreenOrientation {
  PORTRAIT = display.Orientation.PORTRAIT,
  LANDSCAPE = display.Orientation.LANDSCAPE,
  REVERSE_PORTRAIT = display.Orientation.PORTRAIT_INVERTED,
  REVERSE_LANDSCAPE = display.Orientation.LANDSCAPE_INVERTED
}

let context_index = getContext(this) as common.UIAbilityContext;
let resourceDir = context_index.resourceDir

//console.log("Dir"+resourceDir)

const TAG = 'web-savePic';
// UA 常量：默认伪装安卓客户端（Chrome/Android 手机 UA），电脑端为桌面 Chrome
const ANDROID_UA: string = 'Mozilla/5.0 (Linux; Android 14; M2012K11AC Build/UKQ1.230917.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
const PC_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
// 搜图神器网页端主页
const SOUTU_HOME_URL: string = 'https://soutushenqi.com/image/feature';
const context = getContext(this) as common.UIAbilityContext;
/**
 * 复制本地文件到应用沙箱,并返回保存后的沙箱中的文件路径
 */
function copyLocalPicFilesDir(rawfilePath: string, newFileName: string): string {
  let srcFileDescriptor = context.resourceManager.getRawFdSync(rawfilePath); //这里填rawfile文件夹下的文件名（包括后缀）
  let dstPath = context.filesDir + "/" + newFileName;
  let dest: fs.File = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE)
  let bufsize = 4096
  let buf = new ArrayBuffer(bufsize)
  let off = 0, len = 0, readedLen = 0
  while (len = fs.readSync(srcFileDescriptor.fd, buf, { offset: srcFileDescriptor.offset + off, length: bufsize })) {
    readedLen += len
    fs.writeSync(dest.fd, buf, { offset: off, length: len })
    off = off + len
    if ((srcFileDescriptor.length - readedLen) < bufsize) {
      bufsize = srcFileDescriptor.length - readedLen
    }
  }
  fs.close(dest.fd)

  return dest.path;
}




@Entry
@Component
struct Index {
  private isRefreshing: boolean = false;
  @State controller: webview.WebviewController = new webview.WebviewController();
  @State webDownloadFile: IAbstractDownloadHandler = new WebDownloadFileHelper()
  downloadWebLoading: CustomDialogController = new CustomDialogController({
    //Web页面加载的弹窗控制器
    builder: DownloadConfirmDialog(),
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    autoCancel: false,
    isModal: false
  })

  private shouldClearCache: boolean = false;
  // 搜图神器适配：图片详情浮层。详情在独立 Web 实例中打开，返回时销毁浮层，
  // 底层首页/搜索页保持挂载原状（组件不卸载、滚动位置不变、零重载）
  @State detailVisible: boolean = false;
  @State detailUrl: string = '';
  private detailController: webview.WebviewController = new webview.WebviewController();
  private detailDownloadFile: IAbstractDownloadHandler = new WebDownloadFileHelper();
  // Cookie 登录（v1.7.4）：设置面板粘贴网页版 Cookie 写入 WebView CookieStore
  @State savedCookie: string = '';
  @State cookieInput: string = '';
  private cookiePending: boolean = false;
  // 启动性能：Web 首帧 src 用普通属性（非 @State），偏好设置晚于首帧就绪时不再触发二次加载
  private firstSrc: string = SOUTU_HOME_URL;
  private webReady: boolean = false;
  @State refreshing: boolean = false
  @State list: number[] = Array(20).fill(Date.now())
  @State is_home: boolean = false;
  @State showDialog: boolean = false;
  //home_url = "http://nas2.smder.com:3002"
  @State home_url: string = ''
  @State saved_home_url: string = SOUTU_HOME_URL;
  @State c_pg_ua: string = '';
  @State c_ua_temp: string = '';
  @State ua_type: string = 'Mobile';
  @State userAgent: string = '';
  @State ua_device: string = '';
  @State showTopRow: boolean = false;
  @State showRefreshRow: boolean = true;
  @State showButtonRow: boolean = true;
  @State refreshTimerId: number | null = null;
  @State showSetting: boolean = false;
  @State isLandscape: boolean = false;
  @State isLSRefresh: string = 'flase'; //是否横屏不能刷新
  @State isdrag: number = 1
  @State isHidebar: string = 'false';
  @State isHidestatus: string = 'false';
  @State isFull: string = 'true';
  @State slide_num: number = 0.3;
  @State webDark: string = 'auto'; // 'auto'=开关关闭(始终浅色), 'dark'=开关打开(深色跟随系统)
  @State sysDark: boolean = false; // 系统当前是否深色（mediaquery 实时同步）
  // 系统深浅色监听：开关打开时，网页深色随系统切换（系统深色→深色显示，浅色→浅色显示）
  private darkMQL: mediaquery.MediaQueryListener | null = null;
  // 页面内取图桥（__STQ_IMGB64__）分片缓存：reqId -> 已收分片（按 seq 追加）
  private imgChunks: Map<string, string[]> = new Map();
  // reqId -> 期望分片数（-1 表示页面侧取图失败）
  private imgTotal: Map<string, number> = new Map();
  // 沉浸式：状态栏高度留白(px->vp)，供下拉顶栏避开状态栏
  @State safeTopVp: number = 0;
  // 底栏抬高设置值(0-30vp)：设置面板可调，抬高网页视口底部，避免网页底栏被小白条手势区压住
  @State bottomLiftSetting: number = 28;
  // 底栏抬高区填充色：与底部采样色一致（同状态栏避让的取色逻辑）
  @State bottomFillColor: string = '';
  // 主内容区实际高度(vp)：避让/抬高区分段取色的锚点
  @State contentHeightVp: number = 0;
  // 全屏避让填充色：状态栏区域与页面顶部采样色一致，避免色差断层
  @State topFillColor: string = '';
  // 状态栏原生高度(vp)：全屏布局下二三级页面的避让量来源
  private statusVp: number = 0;
  // 当前窗口是否为全屏布局（setWindowLayoutFullScreen(true) 后窗口延伸到状态栏下）
  private fullLayout: boolean = false;
  // 当前主文档 URL：用于区分首页一级界面（保持沉浸不避让）与二三级页面（避让状态栏）
  private pageUrl: string = '';
  private lastTopBg: string = '';
  private lastBottomBg: string = '';
  // 长按上下文菜单（图片/视频）
  @State ctxVisible: boolean = false;
  @State ctxX: number = 0;
  @State ctxY: number = 0;
  @State ctxItems: string[] = [];
  private ctxUrl: string = '';



  async setSystemFull(is_full: string, is_hidestatus: string, is_hidebar: string) {
    let windowClass = await window.getLastWindow(context_index)
    if (is_full == 'true') {
      if (is_hidestatus == 'true') {
        if (is_hidebar == 'true') {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);

        } else {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      } else {
        if (is_hidebar == 'true') {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);

        } else {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      }
    } else {
      if (is_hidestatus == 'true') {
        if (is_hidebar == 'true') {
          // 小白条开启：必须全屏布局。非全屏布局下系统会把导航栏画成默认黑，
          // navigationBarColor 被忽略；全屏布局下窗口延伸到小白条下方，采样色可正常上屏
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);
        } else {
          await windowClass.setWindowLayoutFullScreen(false);
          this.fullLayout = false;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      } else {
        if (is_hidebar == 'true') {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);

          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);

        } else {
          await windowClass.setWindowLayoutFullScreen(false);
          this.fullLayout = false;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      }
    }
    // 系统栏样式：非全屏时状态栏/小白条背景取页面采样色；全屏同理
    await this.updateSystemBarStyle();
    // navigationIndicator 异步生效，会把导航栏颜色重置回系统默认黑：延时重设
    setTimeout(() => {
      this.updateSystemBarStyle(this.lastTopBg, this.lastBottomBg);
    }, 350);
    // 状态栏原生高度：全屏布局下二三级页面避让用；非全屏布局窗口自动避让，不加 padding
    try {
      const area = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusVp = px2vp(area.topRect.top);
    } catch (err) {
      this.statusVp = 0;
    }
    this.pageUrl = this.saved_home_url || '';
    this.updateSafeTop();
  }

  /** 一级界面判定：主文档 URL 与设置的主页一致（去 query/hash、归一尾斜杠）视为首页，保持沉浸不避让 */
  private isTopLevelUrl(url: string): boolean {
    try {
      const norm = (u: string): string => {
        let s = (u || '').split('#')[0].split('?')[0];
        if (s.length > 1 && s.endsWith('/')) {
          s = s.substring(0, s.length - 1);
        }
        return s;
      };
      const home = norm(this.saved_home_url);
      if (home === '') {
        return false;
      }
      return norm(url) === home;
    } catch (err) {
      return false;
    }
  }

  /** 顶部避让量：全屏布局下窗口延伸到状态栏之下，必须整体下移，
   *  否则网页顶部（站点自绘标题栏）会被系统状态栏压住 */
  private updateSafeTop(): void {
    const target: number = (this.fullLayout && this.statusVp > 0) ? this.statusVp : 0;
    if (target !== this.safeTopVp) {
      this.safeTopVp = target;
    }
  }

  /** 渐变分段锚点：顶部避让区结束比例（0-1） */
  private topStop(): number {
    if (this.contentHeightVp <= 0 || this.safeTopVp <= 0) {
      return 0;
    }
    return Math.min(1, this.safeTopVp / this.contentHeightVp);
  }

  /** 渐变分段锚点：底部抬高区开始比例（0-1） */
  private bottomStop(): number {
    if (this.contentHeightVp <= 0 || this.bottomLiftSetting <= 0) {
      return 1;
    }
    return Math.max(0, 1 - this.bottomLiftSetting / this.contentHeightVp);
  }

  async aboutToAppear() {
    // 系统深浅色切换：强制重设系统栏（深色：顶栏#1B1C21/底栏#161920）
    EmitterUtil.on<number>('stq_color_mode_changed', (event) => {
      // 系统深浅色切换：用最近采样色强制重设系统栏
      this.applyImmersiveTheme(this.lastTopBg, this.lastBottomBg, true);
    });
    // 强制深色跟随系统：开关打开时，网页深色随系统深浅色变化
    try {
      this.darkMQL = mediaquery.matchMediaSync('(dark-mode: dark)');
      this.darkMQL.on('change', (res: mediaquery.MediaQueryResult) => {
        this.onSystemDarkChanged(res.matches as boolean);
      });
    } catch (err) {
    }
    // 网页缓存管理：记录最后使用时间；超过 7 天未使用，启动时自动清除缓存
    preferences.getPreferences(context_index, 'stq_web_cache').then((pref) => {
      const now: number = systemDateTime.getTime();
      pref.get('cache_updated_at', 0).then((v) => {
        const last: number = typeof v === 'number' ? v : 0;
        if (last > 0 && now - last > 7 * 24 * 60 * 60 * 1000) {
          this.shouldClearCache = true;
        }
        pref.put('cache_updated_at', now).then(() => {
          pref.flush();
        });
      });
    }).catch(() => {
    });
    EmitterUtil.on<number>('affffa', (event) => {
      if (event?.data === 1) {
        this.downloadWebLoading.open()
      } else {
        this.downloadWebLoading.close()
      }
    })
    // 启动性能：偏好读取并行化（原先 12 次串行 await，每次都阻塞一帧）
    const slidePromise = getSlidenum();
    const prefs: string[] = await Promise.all([
      getLSRefresh(), getUserAgent(), getHomeUrl(), getIshidebar(), getIshidestatus(),
      getUserAgentType(), getIsfull(), getWebDarkMode(), getWebCookie(), getBottomLift()
    ]);
    const slideN: number = await slidePromise;
    this.isLSRefresh = prefs[0] || this.isLSRefresh;
    this.c_pg_ua = prefs[1] || this.c_pg_ua;
    this.c_ua_temp = prefs[1] || this.c_pg_ua;
    this.saved_home_url = prefs[2] || this.saved_home_url;
    this.isHidebar = (prefs[3] || this.isHidebar);
    this.isHidestatus = (prefs[4] || this.isHidestatus);
    this.ua_type = (prefs[5] || this.ua_type);
    this.isFull = (prefs[6] || this.isFull);
    this.slide_num = slideN || this.slide_num;
    this.webDark = (prefs[7] || this.webDark);
    // Cookie 登录：内核已在 EntryAbility 预热，首帧加载前写入可随首个请求生效；
    // 写入失败（内核未就绪）时置 pending，由 onControllerAttached 补写并刷新一次
    this.savedCookie = (prefs[8] || '').trim();
    // 底栏抬高设置值(0-30vp)：默认 28（与 TapTapWeb 壳一致），超界纠正
    const savedLift: number = Number(prefs[9] || '');
    this.bottomLiftSetting = isNaN(savedLift)
      ? 28
      : Math.max(0, Math.min(30, Math.round(savedLift)));
    if (this.savedCookie !== '' && !this.applyWebCookie()) {
      this.cookiePending = true;
    }
    // 启动性能：首帧 src 尚未被消费时直接用真实首页，避免"先默认页再跳转"的二次加载
    if (!this.webReady && this.saved_home_url) {
      this.firstSrc = this.saved_home_url;
    }
    // 初始系统深浅色同步（在偏好读取后执行）：开关打开时按系统深浅色决定网页深色
    try {
      if (this.darkMQL) {
        this.onSystemDarkChanged(this.darkMQL.matches as boolean);
      }
    } catch (err) {
    }
    setTimeout(() => {
      this.backToHome();
      this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
    }, 50);
  }

  aboutToDisappear(): void {
    EmitterUtil.off<number>('affffa', (event) => {

    })
    EmitterUtil.unSubscribe('stq_color_mode_changed');
    try {
      if (this.darkMQL) {
        this.darkMQL.off('change');
        this.darkMQL = null;
      }
    } catch (err) {
    }
  }

  /** 系统深浅色变化：仅开关打开时响应——系统深色→网页深色；系统浅色→网页浅色。开关状态本身不变 */
  private onSystemDarkChanged(sysDark: boolean): void {
    const changed: boolean = sysDark !== this.sysDark;
    this.sysDark = sysDark;
    if (!changed || !this.get_isWebDark()) {
      return;
    }
    this.lastTopBg = '';
    this.lastBottomBg = '';
    this.applyImmersiveTheme('', '', true);
    hilog.info(0x0000, TAG, 'web dark follows system: %{public}s', sysDark ? 'dark' : 'light');
    if (this.webReady) {
      this.refreshWeb();
    }
  }

  /** 网页最终深色状态：强制深色开关打开 且 系统当前为深色（系统浅色时保持浅色显示） */
  private isWebDarkNow(): boolean {
    return this.get_isWebDark() && this.sysDark;
  }

  @Builder
  content() {
    Stack() {
      Column() {
        Row() {
          TextInput({
            placeholder: '请输入有效的URL地址',
            text: this.saved_home_url
          })
            .height(32)
            .width("80%")
            .onChange((value) => {
              this.home_url = value;
            })

          Button('保存')
            .height(32)
            .width("15%")
            .type(ButtonType.Capsule)
            .backgroundColor(Color.Blue)
            .onClick(() => {
              if (this.home_url) {
                saveHomeUrl(this.home_url);
                this.saved_home_url = this.home_url
                this.backToHome();
              }
              this.showTopRow = false
              this.showRefreshRow = true
              this.showButtonRow = true
              //this.isRefreshing = true;
              //this.refreshing = true;
              this.onRefreshing();
            })
        }
        .visibility(this.showTopRow ? Visibility.Visible : Visibility.None)
        .height(40)
        .width("100%")
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.SpaceAround)

        Row() {
          LoadingProgress()
            .height(32)
          Text('正在刷新...')
              .fontColor($r('app.color.dialog_text'))
            .fontSize(16)
            .margin({ left: 20 })
        }
        .visibility(this.showRefreshRow ? Visibility.Visible : Visibility.None)
        .alignItems(VerticalAlign.Center)

        Row() {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.settings'))
              .width(20)
              .height(20)
          }
          .onClick(() => {
            //this.showTopRow = false
            //this.showTopRow = true
            //this.showRefreshRow = false
            //this.showButtonRow = false
            //this.cancelRefresh()
            this.showSetting = true
          })
          .height(32)
          .width(32)

          //.type(ButtonType.Normal)
          Button("清除缓存")
            .onClick(() => {
              this.controller.removeCache(true);
            })
            .height(32)
            .width("25%")
          //.type(ButtonType.Normal)
          Button("返回首页")
            .onClick(() => {
              this.is_home = true
              this.backToHome()
              setTimeout(() => {
                this.is_home = false
              }, 1000);
            })
            .height(32)
            .width("60%")
          //.type(ButtonType.Normal)
          // 条件渲染弹窗

        }
        .visibility(this.showButtonRow ? Visibility.Visible : Visibility.None)
        .padding({ top: 5, bottom: 5 })
        .height(40)
        .width("100%")
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.panel_bg'))
        .justifyContent(FlexAlign.SpaceAround)
      }
      .padding({ top: this.safeTopVp })
    }

  }

  build() {
    Stack() {
      Refresh({ refreshing: $$this.refreshing, builder: this.content() }) {
        NavDestination() {
          Column() {
            Web({ src: this.firstSrc, controller: this.controller })
              .onControllerAttached(() => {
                this.controller.setNetworkAvailable(true);
                this.webDownloadFile.setDownloadDelegate(this.controller);
                if (this.shouldClearCache) {
                  this.shouldClearCache = false;
                  try {
                    this.controller.removeCache(true);
                  } catch (err) {
                  }
                }
                console.info("onControllerAttached");
                try {
                  this.change_userAgent()
                } catch (error) {
                  console.error(`ErrorCode: ${(error as BusinessError).code},  Message: ${(error as BusinessError).message}`);
                }
                // Cookie 登录兜底：aboutToAppear 时内核未就绪导致写入失败的，这里补写；
                // 补写成功后整页加载真实首页（缓存打底页若在则被替换），保证登录态随请求生效
                if (this.cookiePending) {
                  this.cookiePending = false;
                  if (this.applyWebCookie()) {
                    setTimeout(() => {
                      try {
                        this.controller.loadUrl(this.saved_home_url || SOUTU_HOME_URL);
                      } catch (err) {
                      }
                    }, 300);
                  }
                }
              })
              //.cacheMode(CacheMode.Online)
              .domStorageAccess(true)
              //.multiWindowAccess(true)
              .javaScriptAccess(true)
              .geolocationAccess(true)
              .imageAccess(true)
              .onlineImageAccess(true)
              .fileAccess(true)
              .mediaPlayGestureAccess(true)
              .mixedMode(MixedMode.Compatible)
              .darkMode(this.isWebDarkNow() ? WebDarkMode.On : WebDarkMode.Off)
              .forceDarkAccess(this.isWebDarkNow())
              .backgroundColor($r('app.color.panel_bg'))
              .javaScriptOnDocumentStart([{ script: WEB_CHROME_SCRIPT, scriptRules: ['*'] }])
              .onConsole((event) => {
                // 沉浸式取色桥：页面探针经 console 上报主题背景色
                if (event && event.message) {
                  const msg: string = event.message.getMessage() || '';
                  if (msg.indexOf('__STQ_IMGB64__') === 0) {
                    return this.handleImgBridge(msg);
                  }
                  if (msg.indexOf('__STQ_CHROME__') === 0) {
                    try {
                      const payload = JSON.parse(msg.substring('__STQ_CHROME__'.length)) as Record<string, string>;
                      this.applyImmersiveTheme(payload.bg || '', payload.bbg || '');
                    } catch (err) {
                    }
                  } else if (msg.indexOf('__STQ_DETAIL__') === 0) {
                    // SPA 路由桥：站点客户端路由进详情页已被注入脚本截获（主文档不导航），
                    // 这里改由详情浮层承载——底层列表页保持挂载，返回时不重载、不丢滚动位置
                    const durl: string = msg.substring('__STQ_DETAIL__'.length);
                    if (durl !== '' && !this.detailVisible) {
                      this.openDetailOverlay(durl);
                    }
                  }
                }
                return false;
              })
              .onContextMenuShow((event) => {
                return this.handleWebContextMenu(event);
              })
              .onLoadIntercept((event) => {
                // 拦截非网页协议的跳转，交给系统/外部应用打开（如应用深链 scheme）
                if (event && event.data) {
                  const url: string = event.data.getRequestUrl() || '';
                  const scheme: string = url.split(':')[0]?.toLowerCase() || '';
                  const webSchemes: string[] = ['http', 'https', 'file', 'about', 'data', 'blob', 'javascript'];
                  if (scheme !== '' && !webSchemes.includes(scheme)) {
                    this.openExternalApp(url);
                    return true; // 拦截，不让 WebView 自己加载
                  }
                  // 主文档导航：按页面层级刷新状态栏避让（首页沉浸，二三级避让）
                  if ((scheme === 'http' || scheme === 'https') && event.data.isMainFrame()) {
                    // 搜图神器适配：详情页一律交由浮层 Web 承载，主 Web 永不加载详情——
                    // 底层列表页保持挂载原状，关闭浮层时滚动位置与已加载数据零丢失
                    //（兜底站点"路由中断后回退 location.href 直跳"的路径：浮层未开时先开浮层）
                    if (this.isDetailUrl(url)) {
                      if (!this.detailVisible) {
                        this.openDetailOverlay(url);
                      }
                      return true;
                    }
                    this.pageUrl = url;
                    this.updateSafeTop();
                  }
                }
                return false;
              })
              .onShowFileSelector((event) => {
                // 搜图神器网页适配：<input type=file>（以图搜图上传）拉起系统图库选图。
                // ArkWeb 默认不处理网页文件选择，必须接管并回传文件句柄
                try {
                  const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
                  photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
                  photoSelectOptions.maxSelectNumber = 1;
                  const photoPicker = new photoAccessHelper.PhotoViewPicker();
                  photoPicker.select(photoSelectOptions).then((photoSelectResult) => {
                    if (photoSelectResult.photoUris && photoSelectResult.photoUris.length > 0) {
                      // 本地 SDK 兼容：FileSelectorResult.handleFileList 只接受 Array<string>（文件 URI 列表），
                      // 原写法传 {uri,fileName,fd} 对象数组会被 ArkTS 静态检查拒绝（untyped-obj-literals）
                      const fileList: string[] = [];
                      for (const photoUri of photoSelectResult.photoUris) {
                        fileList.push(photoUri);
                      }
                      event.result.handleFileList(fileList);
                    } else {
                      event.result.handleFileList([]);
                    }
                  }).catch(() => {
                    try {
                      event.result.handleFileList([]);
                    } catch (err) {
                    }
                  });
                } catch (err) {
                  try {
                    event.result.handleFileList([]);
                  } catch (err2) {
                  }
                  return false;
                }
                return true;
              })

          }
          .width("100%")
          .height("100%")
          // 顶部：全屏布局下整体下移，网页顶部（站点标题栏）不被系统状态栏遮挡；
          // 底部：抬高 0-30vp（设置面板可调），网页底栏不被小白条手势区压住
          .padding({ top: this.safeTopVp, bottom: this.bottomLiftSetting })
          // 避让/抬高区分段取色：上段用页面顶部采样色、下段用页面底部采样色（与系统栏同逻辑），
          // 无采样时回退 panel_bg（浅色资源自适配深浅色）
          .linearGradient({
            angle: 180,
            colors: [
              [this.topFillColor === '' ? $r('app.color.panel_bg') : this.topFillColor, 0],
              [this.topFillColor === '' ? $r('app.color.panel_bg') : this.topFillColor, this.topStop()],
              [this.bottomFillColor === '' ? $r('app.color.panel_bg') : this.bottomFillColor, this.bottomStop()],
              [this.bottomFillColor === '' ? $r('app.color.panel_bg') : this.bottomFillColor, 1]
            ]
          })
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            const h: number = Number(newArea.height) || 0;
            if (h > 0 && Math.abs(h - this.contentHeightVp) > 0.5) {
              this.contentHeightVp = h;
            }
          })

        }

      }
      .pullDownRatio(this.slide_num * this.isdrag)
      .backgroundColor($r('app.color.panel_bg'))
      .onRefreshing(() => this.onRefreshing())
      .onSizeChange(() => {
        window.getLastWindow(this.getUIContext().getHostContext(), (err, win) => {
          let cutOutInfo = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM_GESTURE)
          //console.log(JSON.stringify(cutOutInfo))
          if (window.Orientation.AUTO_ROTATION) {
            let rotation: number =
              display.getDefaultDisplaySync().orientation // Get current screen orientation enum value
            //console.log('' + rotation);
            if (this.isLSRefresh == 'true') {
              if (rotation == 0) {
                this.isLandscape = false;
                this.isdrag = 1;
                //console.log("CutOutInfo Portrait data: " + JSON.stringify(cutOutInfo));
              } else if (rotation == 1) {
                this.isLandscape = true;
                this.isdrag = 0;
                //console.log("CutOutInfo Landscape data: " + JSON.stringify(cutOutInfo));
              } else if (rotation == 2) {
                this.isLandscape = false;
                this.isdrag = 1;
                //console.log("CutOutInfo Reverse portrait data: " + JSON.stringify(cutOutInfo));
              } else {
                this.isLandscape = true;
                this.isdrag = 0;
                //console.log("CutOutInfo Reverse landscape data: " + JSON.stringify(cutOutInfo));
              }
            }
          }
        })
      })
      .width('100%')
      .height('100%')

      // 搜图神器适配：详情浮层（独立 Web 加载详情，返回销毁浮层，底层页面不重载）
      if (this.detailVisible) {
        Stack() {
          Web({ src: this.detailUrl, controller: this.detailController })
            .onControllerAttached(() => {
              this.detailController.setNetworkAvailable(true);
              this.detailDownloadFile.setDownloadDelegate(this.detailController);
              try {
                this.detailController.setCustomUserAgent(this.getuseragentbytype(this.ua_type));
              } catch (error) {
              }
            })
            .onConsole((event) => {
              // 沉浸式取色桥：与主 Web 同一探针，浮层期间系统栏跟随详情页配色
              if (event && event.message) {
                const msg: string = event.message.getMessage() || '';
                if (msg.indexOf('__STQ_IMGB64__') === 0) {
                  return this.handleImgBridge(msg);
                }
                if (msg.indexOf('__STQ_CHROME__') === 0) {
                  try {
                    const payload = JSON.parse(msg.substring('__STQ_CHROME__'.length)) as Record<string, string>;
                    this.applyImmersiveTheme(payload.bg || '', payload.bbg || '');
                  } catch (err) {
                  }
                }
              }
              return false;
            })
            .onContextMenuShow((event) => {
              return this.handleWebContextMenu(event);
            })
            .onLoadIntercept((event) => {
              if (event && event.data) {
                const url: string = event.data.getRequestUrl() || '';
                const scheme: string = url.split(':')[0]?.toLowerCase() || '';
                const webSchemes: string[] = ['http', 'https', 'file', 'about', 'data', 'blob', 'javascript'];
                if (scheme !== '' && !webSchemes.includes(scheme)) {
                  this.openExternalApp(url);
                  return true;
                }
                // 详情页内站点返回按钮路由回首页时：关闭浮层露出未重载的底层页面
                if ((scheme === 'http' || scheme === 'https') && event.data.isMainFrame()) {
                  if (this.isTopLevelUrl(url) || this.isHomePathUrl(url)) {
                    this.closeDetailOverlay();
                    return true;
                  }
                }
              }
              return false;
            })
            .domStorageAccess(true)
            .javaScriptAccess(true)
            .geolocationAccess(true)
            .imageAccess(true)
            .onlineImageAccess(true)
            .fileAccess(true)
            .mediaPlayGestureAccess(true)
            .mixedMode(MixedMode.Compatible)
            .darkMode(this.isWebDarkNow() ? WebDarkMode.On : WebDarkMode.Off)
            .forceDarkAccess(this.isWebDarkNow())
            .javaScriptOnDocumentStart([{ script: WEB_CHROME_SCRIPT, scriptRules: ['*'] }])
            .backgroundColor($r('app.color.panel_bg'))
            .width('100%')
            .height('100%')

          // 浮层返回键：站点详情页返回键在独立历史栈里可能失效，提供可靠出口
          Button() {
            Text('←')
              .fontSize(20)
              .fontColor(Color.White)
          }
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .backgroundColor('#59000000')
          .margin({ top: this.statusVp + 12, left: 12 })
          .onClick(() => {
            this.closeDetailOverlay();
          })
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.TopStart)
      }

      //弹窗
      Column() {
        Column() {
          Row() {
            Text("首页")
              .fontColor($r('app.color.dialog_text'))
              .width("12%")
              .height(32)
            TextInput({
              placeholder: '请输入有效的URL地址',
              text: this.saved_home_url
            })
              .height(32)
              .width("70%")
              .padding({
                top: '4vp',
                right: '12vp',
                bottom: '4vp',
                left: '12vp'

              })
              .onChange((value) => {
                this.home_url = value;
              })
            Text()
              .width(7)

            Button('保存')
              .height(32)
              .width("18%")
              .type(ButtonType.Capsule)
              //.backgroundColor(Color.Blue)
              .onClick(() => {
                if (this.home_url) {
                  saveHomeUrl(this.home_url);
                  this.saved_home_url = this.home_url;
                  this.backToHome();
                }
              })
          }
          // 搜图神器壳：首页地址行常显（原壳 1.7.9 默认隐藏，这里恢复）
          .visibility(Visibility.Visible)

          Row()
            .height(10)

          // 搜图神器壳：UA 选择行常显（默认手机=安卓客户端 UA）
          // 三个选项等分剩余宽度并单行省略——原写法各 Text 不限宽，中文标签会把设置面板边框撑破
          Row() {
            Text("UA")
              .fontColor($r('app.color.dialog_text'))
              .fontSize(14)
              .width('12%')

            Row() {
              Radio({ value: 'Mobile', group: 'ua_type_group' })
                .checked(this.ua_type === 'Mobile')
                .onChange((isChecked) => {
                  if (isChecked) {
                    this.ua_type = 'Mobile';
                    saveUserAgentType('Mobile');
                    this.change_userAgent();
                    this.refreshWeb();
                  }
                })
                .height(20)
                .width(20)
              Text("手机(安卓)")
                .fontColor($r('app.color.dialog_text'))
                .fontSize(12)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  if (this.ua_type == 'custom') {
                    this.c_ua_temp = this.getuseragentbytype('Mobile');
                  }
                })
            }
            .layoutWeight(1)

            Row() {
              Radio({ value: 'PC', group: 'ua_type_group' })
                .checked(this.ua_type === 'PC')
                .onChange((isChecked) => {
                  if (isChecked) {
                    this.ua_type = 'PC';
                    saveUserAgentType('PC');
                    this.change_userAgent();
                    this.refreshWeb();
                  }
                })
                .height(20)
                .width(20)
              Text("电脑")
                .fontColor($r('app.color.dialog_text'))
                .fontSize(12)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  if (this.ua_type == 'custom') {
                    this.c_ua_temp = this.getuseragentbytype('PC');
                  }
                })
            }
            .layoutWeight(1)

            Row() {
              Radio({ value: 'custom', group: 'ua_type_group' })
                .checked(this.ua_type === 'custom')
                .onChange((isChecked) => {
                  if (isChecked) {
                    this.ua_type = 'custom';
                    saveUserAgentType('custom');
                    this.change_userAgent();
                    this.refreshWeb();
                  }
                })
                .height(20)
                .width(20)
              Text("自定义")
                .fontColor($r('app.color.dialog_text'))
                .fontSize(12)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  if (this.ua_type == 'custom') {
                    this.c_ua_temp = this.getuseragentbytype('custom');
                  }
                })
            }
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            TextArea({
              text: this.c_ua_temp,
              placeholder: '输入UA（可不填）。点上方[手机][电脑][自定义]文字可复制其UA'
            })
              .placeholderFont({ size: 13 })
              .fontSize(14)
              .height(170)
              .textAlign(TextAlign.Start)
              .layoutWeight(1)
              .onChange((value) => {
                this.c_ua_temp = value;
              })

            Text()
              .width(7)

            Button('保存')
              .height(32)
              .width(72)
              .type(ButtonType.Capsule)
              //.backgroundColor(Color.Blue)
              .onClick(() => {
                if (this.c_ua_temp) {
                  this.c_pg_ua = this.c_ua_temp;
                  saveUserAgent(this.c_pg_ua);
                  this.change_userAgent()
                  this.refreshWeb();
                }
              })
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
          Row()
            .height(10)

          Row() {
            Text("横屏禁止刷新")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isLSRefresh()
            })
              .width('15%')
              .height(25)
              //.selectedColor(Color.Blue)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isLSRefresh = 'true';
                  saveLSRefresh(this.isLSRefresh);
                  if (this.isLandscape == true) {
                    this.isdrag = 1;
                  } else {
                    this.isdrag = 0;
                  }
                } else {
                  this.isLSRefresh = 'false';
                  saveLSRefresh(this.isLSRefresh);
                  this.isdrag = 1;
                }

              })

          }
          .justifyContent(FlexAlign.SpaceAround)
          .width('100%')

          Row() {
            Text("全屏模式")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isfull()
            })
              .width('15%')
              .height(25)
              //.selectedColor(Color.Blue)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isFull = 'true';
                  saveIsfull(this.isFull);
                } else {
                  this.isFull = 'false';
                  saveIsfull(this.isFull);
                }
                this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
              })
          }

          Row() {
            Text("显示状态栏")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isHideStatus()
            })
              .width('15%')
              .height(25)
              //.selectedColor(Color.Blue)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isHidestatus = 'true';
                  saveIshidestatus(this.isHidestatus);
                } else {
                  this.isHidestatus = 'false';
                  saveIshidestatus(this.isHidestatus);
                }
                //this.setSystemStatus(this.isHidestatus);
                this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
              })
          }

          Row() {
            Text("显示底部白条")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isHideBar()
            })
              .width('15%')
              .height(25)
              //.selectedColor(Color.Blue)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isHidebar = 'true';
                  saveIshidebar(this.isHidebar);
                } else {
                  this.isHidebar = 'false';
                  saveIshidebar(this.isHidebar);
                }
                //this.setSystemBar(this.isHidebar);
                this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
              })
          }


          Row() {
            Text("强制深色模式")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isWebDark()
            })
              .width('15%')
              .height(25)
              .onChange((isOn: boolean) => {
                this.webDark = isOn ? 'dark' : 'auto';
                saveWebDarkMode(this.webDark);
                this.lastTopBg = '';
                this.lastBottomBg = '';
                this.applyImmersiveTheme('', '', true);
                this.refreshWeb();
                // 开关打开瞬间即按当前系统深浅色生效，无需等下一次系统切换
                this.onSystemDarkChanged(this.sysDark);
              })
          }

          Row() {
            Text("下拉灵敏度")
              .fontColor($r('app.color.dialog_text'))
              .width("30%")
              .height(32)
            Text()
              .width('10%')
            Slider({
              value: this.slide_num * 100,
              step: 10,
              min: 10,
              style: SliderStyle.InSet
            })
              .width('50%')
              .height(25)
              .showSteps(true)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.slide_num = value / 100;
                saveSlidenum(value / 100);
              })
            Text((this.slide_num * 100).toFixed(0))
              .width('10%')
              .height(32)
              .textAlign(TextAlign.End)

          }

          Row() {
            Text("底栏抬高")
              .fontColor($r('app.color.dialog_text'))
              .width("30%")
              .height(32)
            Text()
              .width('10%')
            Slider({
              value: this.bottomLiftSetting,
              step: 1,
              min: 0,
              max: 30,
              style: SliderStyle.InSet
            })
              .width('50%')
              .height(25)
              .showSteps(true)
              .onChange((value: number, mode: SliderChangeMode) => {
                const v: number = Math.max(0, Math.min(30, Math.round(value)));
                if (v === this.bottomLiftSetting && mode !== SliderChangeMode.End) {
                  return;
                }
                this.bottomLiftSetting = v;
                saveBottomLift(String(v));
              })
            Text(this.bottomLiftSetting.toFixed(0))
              .width('10%')
              .height(32)
              .textAlign(TextAlign.End)

          }

          Row()
            .height(30)

          Row() {
            Text("Version:1.1.1")
              .fontColor($r('app.color.dialog_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
          }


          Row()
            .height(20)

          // Cookie 登录逻辑保留（fetchCurrentCookie/applyWebCookie），UI 按需求隐藏；
          // 已保存的 Cookie 仍在启动/页面加载时自动写入
          Row() {
            Text('登录 Cookie')
              .fontColor($r('app.color.dialog_text'))
              .width('30%')
              .height(40)
            TextInput({
              placeholder: '粘贴网页版 Cookie',
              text: this.cookieInput
            })
              .height(40)
              .layoutWeight(1)
              .fontSize(13)
              .onChange((value: string) => {
                this.cookieInput = value;
              })

            Button('应用')
              .type(ButtonType.Capsule)
              .backgroundColor($r('app.color.dialog_text_secondary'))
              .margin({ left: 8 })
              .height(40)
              .width(72)
              .onClick(() => {
                const raw = (this.cookieInput || '').trim();
                if (raw === '') {
                  promptAction.showToast({ message: '请先粘贴 Cookie 串' });
                  return;
                }
                this.savedCookie = raw;
                saveWebCookie(raw);
                const ok = this.applyWebCookie();
                this.showSetting = false;
                if (ok) {
                  promptAction.showToast({ message: 'Cookie 已写入，刷新登录态' });
                  this.refreshWeb();
                } else {
                  this.cookiePending = true;
                  promptAction.showToast({ message: '内核未就绪，页面加载时自动重试' });
                }
              })
          }
          .width('100%')
          .visibility(Visibility.None)

          // 获取当前账号 Cookie（v1.7.5）：应用内已登录时一键取出 WebView 现有登录 Cookie，
          // 填入上方输入框供查看/复制，再点"应用"固化到双域（与手动粘贴输入并存）
          Row() {
            Text('应用内已登录时，可一键取出当前登录 Cookie')
              .fontSize(11)
              .fontColor($r('app.color.dialog_text_secondary'))
              .layoutWeight(1)
            Button('获取当前 Cookie')
              .type(ButtonType.Capsule)
              .backgroundColor($r('app.color.dialog_text_secondary'))
              .height(32)
              .fontSize(12)
              .onClick(() => {
                const got = this.fetchCurrentCookie();
                if (got === '') {
                  promptAction.showToast({ message: '未取到 Cookie，请先在应用内登录' });
                  return;
                }
                this.cookieInput = got;
                promptAction.showToast({ message: '已填入当前 Cookie，点"应用"生效' });
              })
          }
          .width('100%')
          .margin({ top: 8 })
          .visibility(Visibility.None)

          Row()
            .height(16)

          Row() {
            Button('返回')
              .type(ButtonType.Capsule)
              //.backgroundColor(Color.Blue)
              .onClick(() => {
                this.showSetting = false
                this.c_ua_temp = this.c_pg_ua;
                //this.cancelRefresh()
                //this.refreshWeb();
              })
              .height(40)
              .width(100)
          }

        }
        .width("90%")
        //.height("70%")
        .padding(20)
        .backgroundColor($r('app.color.panel_bg'))
        .borderRadius($r('sys.float.corner_radius_level8'))
      }
      .width("100%")
      .height("100%")
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Transparent)
      .visibility(this.showSetting ? Visibility.Visible : Visibility.None)

      // 长按菜单点击遮罩（点击空白关闭）
      if (this.ctxVisible) {
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.ctxVisible = false;
          })
      }

      // 长按图片/视频 自绘上下文菜单（参考 aira-browser 自绘 overlay 方案）
      if (this.ctxVisible) {
        Column() {
          ForEach(this.ctxItems, (item: string) => {
            Text(item)
              .fontSize(15)
              .fontColor($r('app.color.dialog_text'))
              .height(44)
              .width(170)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.onCtxItem(item);
              })
            if (item !== this.ctxItems[this.ctxItems.length - 1]) {
              Divider()
                .color($r('app.color.ctx_divider'))
                .width(150)
            }
          }, (item: string) => item)
        }
        .backgroundColor($r('app.color.ctx_menu_bg'))
        .borderRadius(12)
        .shadow({ radius: 16, color: '#26000000' })
        .position({ x: this.ctxX, y: this.ctxY })
      }

    }
    .height('100%')
    .width('100%')

  }

  onBackPress() {
    // 详情浮层打开时：系统侧滑返回=关闭浮层（底层页面不重载）
    if (this.detailVisible) {
      this.closeDetailOverlay();
      return true;
    }
    // 当前页面是否可前进或者后退给定的step步(-1),正数代表前进，负数代表后退
    if (this.controller.accessStep(-1)) {
      this.controller.backward(); // 返回上一个web页
      // 执行用户自定义返回逻辑
      return true
    } else {
      // 执行系统默认返回逻辑，返回上一个page页
      return false
    }
  }

  onRefreshing() {
    // 清除已有定时器
    //this.clearRefreshTimer();
    // 设置新的定时器
    this.refreshTimerId = setTimeout(() => {
      this.list = Array(20).fill(Date.now());
      this.refreshing = false;

      if (!this.is_home) {
        this.refreshWeb();
        this.is_home = false;
        promptAction.showToast({ message: '刷新成功' });
      }
    }, 1000);
  }

  // 统一清除定时器方法
  private clearRefreshTimer() {
    if (this.refreshTimerId !== null) {
      clearTimeout(this.refreshTimerId);
      this.refreshTimerId = null;
    }
  }

  private refreshWeb() {
    if (this.isRefreshing) {
      return;
    }
    this.isRefreshing = true;
    // 执行刷新
    this.controller.refresh();

    //刷新完成后恢复
    setTimeout(() => {
      // this.translateY = 0;
      this.isRefreshing = false;
    }, 1000);
  }

  // 中断刷新函数
  private cancelRefresh() {
    this.clearRefreshTimer(); // 统一清除
    this.isRefreshing = true;
    this.refreshing = true;
    this.controller.stop();
  }

  /** 详情页判定：路径含 /detail（/image/detail、/imgColorExtract/detail 等） */
  private isDetailUrl(url: string): boolean {
    try {
      const p = url.indexOf('/', url.indexOf('//') + 2);
      const path = p >= 0 ? url.substring(p) : '';
      return path.indexOf('/detail') >= 0;
    } catch (err) {
      return false;
    }
  }

  /** 首页路由判定：路径以 /image/feature 开头（含同路径带 query/hash） */
  private isHomePathUrl(url: string): boolean {
    try {
      const p = url.indexOf('/', url.indexOf('//') + 2);
      const path = p >= 0 ? url.substring(p) : '/';
      return path.split('?')[0].split('#')[0].indexOf('/image/feature') === 0;
    } catch (err) {
      return false;
    }
  }

  /** 打开详情浮层：详情在独立 Web 实例中加载，底层页面保持挂载 */
  openDetailOverlay(url: string) {
    // 记录打开前底层页面 URL，用于下面的自愈判定
    let before: string = '';
    try {
      before = this.controller.getUrl() || '';
    } catch (err) {
      before = '';
    }
    this.detailUrl = url;
    this.detailVisible = true;
    // 自愈：注入脚本靠抛哨兵异常中断站点客户端路由提交；若站点改版使中断失效，
    // 底层 WebView 会自己落到详情页（与浮层重复显示）——在浮层遮挡期间回退一步，
    // 关掉浮层时看到的仍是原列表页
    if (before.indexOf('/detail') < 0) {
      setTimeout(() => {
        try {
          const cur: string = this.controller.getUrl() || '';
          if (cur.indexOf('/detail') >= 0 && this.controller.accessStep(-1)) {
            this.controller.backward();
          }
        } catch (err) {
        }
      }, 900);
    }
  }

  /** 关闭详情浮层：销毁浮层 Web，底层首页/搜索页保持挂载原状（不重载、滚动位置不变） */
  closeDetailOverlay() {
    if (!this.detailVisible) {
      return;
    }
    this.detailVisible = false;
    this.detailUrl = '';
    // 浮层期间系统栏颜色可能被详情页采样覆盖：让底层页面重报一次主题色
    try {
      this.controller.runJavaScript('window.__stqScheduleTheme && window.__stqScheduleTheme()');
    } catch (err) {
    }
  }

  // 返回首页
  backToHome() {
    // 详情浮层打开时：关掉浮层即可露出未重载的底层页面，不做整页加载
    if (this.detailVisible) {
      this.closeDetailOverlay();
      return;
    }
    // 启动性能：当前已在目标首页（首帧 src 命中）时跳过，避免同 URL 重复加载
    try {
      const target = this.saved_home_url || SOUTU_HOME_URL;
      let current = '';
      try {
        current = this.controller.getUrl() || '';
      } catch (e) {
        current = '';
      }
      if (current !== '' && current === target) {
        return;
      }
      // 站点客户端路由已经进到详情页（浮层未开）时，优先历史回退——loadUrl 会整页重载
      if (current.indexOf('/detail') >= 0 && this.controller.accessStep(-1)) {
        this.controller.backward();
        return;
      }
      this.controller.loadUrl(target);
    } catch (err) {
    }
  }

  /** 获取当前 Cookie：从 WebView CookieStore 读出搜图神器两个域的现有 Cookie，
   * 按名称去重合并（账号域后写、覆盖主站同名项，保证登录态优先），
   * 拼成 k=v; k=v 串返回。空串表示取不到（未登录/内核未就绪） */
  private fetchCurrentCookie(): string {
    const names: string[] = [];
    const values: string[] = [];
    const sources: string[] = ['https://soutushenqi.com', 'https://web-assets.soutushenqi.com'];
    for (let s = 0; s < sources.length; s++) {
      let raw = '';
      try {
        raw = webview.WebCookieManager.fetchCookieSync(sources[s]) || '';
      } catch (err) {
        raw = '';
      }
      const parts = raw.split(';');
      for (let i = 0; i < parts.length; i++) {
        const kv = parts[i].trim();
        const eq = kv.indexOf('=');
        if (eq <= 0) {
          continue;
        }
        const name = kv.substring(0, eq).trim();
        const value = kv.substring(eq + 1).trim();
        if (name === '' || value === '') {
          continue;
        }
        let idx = -1;
        for (let j = 0; j < names.length; j++) {
          if (names[j] === name) {
            idx = j;
            break;
          }
        }
        if (idx >= 0) {
          values[idx] = value;
        } else {
          names.push(name);
          values.push(value);
        }
      }
    }
    let out = '';
    for (let j = 0; j < names.length; j++) {
      out = out + (out === '' ? '' : '; ') + names[j] + '=' + values[j];
    }
    return out;
  }

  /** Cookie 登录：把用户粘贴的 Cookie 串逐对写入
   * soutushenqi.com 域，写入后随请求自动携带。
   * 返回是否成功写入；串为空返回 false（不置 pending） */
  private applyWebCookie(): boolean {
    const raw = (this.savedCookie || '').trim();
    if (raw === '') {
      return false;
    }
    let ok = false;
    try {
      const parts = raw.split(';');
      for (let i = 0; i < parts.length; i++) {
        const kv = parts[i].trim();
        if (kv.indexOf('=') <= 0) {
          continue;
        }
        try {
          webview.WebCookieManager.configCookieSync('https://soutushenqi.com', kv);
          ok = true;
        } catch (err) {
        }
      }
    } catch (e) {
      return false;
    }
    return ok;
  }

  // 用系统/外部应用打开非网页协议链接（如应用深链 scheme）
  async openExternalApp(url: string) {
    const uiContext = getContext(this) as common.UIAbilityContext;
    try {
      // 优先走系统链接分发（Deep Linking / App Linking），可拉起注册了该协议的应用
      let linkOptions: OpenLinkOptions = { appLinkingOnly: false };
      await uiContext.openLink(url, linkOptions);
      return;
    } catch (e) {
    }
    try {
      // 兜底：显式构造 Want 拉起
      let want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      await uiContext.startAbility(want);
      return;
    } catch (err) {
    }
    promptAction.showToast({ message: '未找到可以打开此链接的应用' });
  }


  get_isWebDark(): boolean {
    return this.webDark === 'dark';
  }

  /** 长按网页图片/视频 -> 接管系统菜单，弹自绘菜单（移植自 aira-browser 长按上下文菜单方案） */
  handleWebContextMenu(event: OnContextMenuShowEvent): boolean {
    try {
      if (!event || !event.param) {
        return false;
      }
      const param = event.param;
      let mediaType: number = -1;
      try {
        mediaType = Number(param.getMediaType());
      } catch (err) {
        mediaType = -1;
      }
      let sourceUrl: string = '';
      try {
        sourceUrl = param.getSourceUrl() || '';
      } catch (err) {
        sourceUrl = '';
      }
      let xPx: number = 0;
      let yPx: number = 0;
      try {
        xPx = Number(param.x());
        yPx = Number(param.y());
      } catch (err) {
        xPx = 0;
        yPx = 0;
      }
      // 图片/视频之外的（纯文本、普通区域）走系统默认
      if (mediaType !== 1 && mediaType !== 2 && mediaType !== 3) {
        return false;
      }
      if (!sourceUrl) {
        return false;
      }
      this.ctxUrl = sourceUrl;
      if (mediaType === 1) {
        this.ctxItems = ['保存图片', '复制图片链接'];
      } else {
        this.ctxItems = ['复制视频链接', '其他应用打开'];
      }
      // 坐标 px -> vp，并夹在屏幕内（菜单约 170vp 宽）
      const screenWVp: number = px2vp(display.getDefaultDisplaySync().width);
      const screenHVp: number = px2vp(display.getDefaultDisplaySync().height);
      this.ctxX = Math.min(Math.max(px2vp(xPx), 8), Math.max(screenWVp - 178, 8));
      this.ctxY = Math.min(Math.max(px2vp(yPx), 8), Math.max(screenHVp - 140, 8));
      if (event.result) {
        try {
          event.result.closeContextMenu();
        } catch (err) {
        }
      }
      this.ctxVisible = true;
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 解析页面内取图桥的分片消息：__STQ_IMGB64__<reqId>:<seq|meta|err>:<total>:<chunk> */
  private handleImgBridge(msg: string): boolean {
    try {
      const prefix = '__STQ_IMGB64__';
      const rest: string = msg.substring(prefix.length);
      const c1: number = rest.indexOf(':');
      if (c1 <= 0) {
        return true;
      }
      const reqId: string = rest.substring(0, c1);
      const c2: number = rest.indexOf(':', c1 + 1);
      if (c2 <= 0) {
        return true;
      }
      const tag: string = rest.substring(c1 + 1, c2);
      if (tag === 'err') {
        // 页面侧取图失败：置 -1 让等待方立即退出
        this.imgTotal.set(reqId, -1);
        return true;
      }
      const c3: number = rest.indexOf(':', c2 + 1);
      if (tag === 'meta') {
        const total: number = Number(rest.substring(c2 + 1, c3 < 0 ? rest.length : c3)) || 0;
        this.imgTotal.set(reqId, total);
        if (!this.imgChunks.has(reqId)) {
          this.imgChunks.set(reqId, []);
        }
        return true;
      }
      const seq: number = Number(tag);
      if (isNaN(seq)) {
        return true;
      }
      // 数据分片格式 reqId:seq:total:chunk；base64 不含 ':'，直接取最后一段
      const chunk: string = c3 >= 0 ? rest.substring(c3 + 1) : rest.substring(c2 + 1);
      let parts: string[] | undefined = this.imgChunks.get(reqId);
      if (!parts) {
        parts = [];
        this.imgChunks.set(reqId, parts);
      }
      parts.push(chunk);
      return true;
    } catch (err) {
      return true;
    }
  }

  /** 兜底取图：在 WebView 页面上下文内 fetch（同 <img> 的 Cookie/UA/凭证上下文），base64 分片回传 */
  private async fetchImageViaPage(url: string): Promise<ArrayBuffer | null> {
    const ctl: webview.WebviewController =
      this.detailVisible ? this.detailController : this.controller;
    const reqId: string = 'r' + Date.now().toString();
    this.imgChunks.delete(reqId);
    this.imgTotal.delete(reqId);
    try {
      await ctl.runJavaScript('window.__stqFetchImage && window.__stqFetchImage('
        + JSON.stringify(reqId) + ',' + JSON.stringify(url) + ')');
    } catch (err) {
      const be = err as BusinessError;
      hilog.warn(0x0000, TAG, 'page fetch inject fail: %{public}s', (be && be.message) ? be.message : '?');
      return null;
    }
    const deadline: number = Date.now() + 20000;
    while (Date.now() < deadline) {
      const total: number = this.imgTotal.get(reqId) || 0;
      if (total === -1) {
        hilog.warn(0x0000, TAG, 'page fetch rejected by page context (CORS/网络)');
        return null;
      }
      const parts: string[] | undefined = this.imgChunks.get(reqId);
      if (total > 0 && parts && parts.length >= total) {
        let b64: string = '';
        for (let i = 0; i < total; i++) {
          b64 += (parts[i] || '');
        }
        try {
          const helper = new util.Base64Helper();
          const u8: Uint8Array = helper.decodeSync(b64);
          return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
        } catch (err) {
          hilog.warn(0x0000, TAG, 'page fetch base64 decode fail');
          return null;
        }
      }
      await this.sleepMs(120);
    }
    hilog.warn(0x0000, TAG, 'page fetch timeout');
    return null;
  }

  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 长按保存图片：原生多 Referer 直取 → 失败回退页面内 fetch → 字节落图库（弹窗/选择器双通道） */
  private async saveWebImage(url: string): Promise<void> {
    const ctl: webview.WebviewController =
      this.detailVisible ? this.detailController : this.controller;
    let pageUrl: string = '';
    try {
      pageUrl = ctl.getUrl() || '';
    } catch (err) {
      pageUrl = '';
    }
    let cookie: string = '';
    try {
      cookie = webview.WebCookieManager.fetchCookieSync(url) || '';
    } catch (err) {
      cookie = '';
    }
    // 1) 原生直取（Referer 依次：当前页 URL → 空 → 图片自身 origin）
    try {
      const data: ArrayBuffer =
        await WebImageSaver.fetchImageEx(url, pageUrl, cookie, this.userAgent);
      if (data && data.byteLength > 0) {
        await WebImageSaver.saveImageBytes(context_index, data, url);
        return;
      }
    } catch (err) {
      const be = err as BusinessError;
      hilog.warn(0x0000, TAG, 'native fetch all strategies failed: %{public}s',
        (be && be.message) ? be.message : '?');
    }
    // 2) 页面内 fetch 兜底（同源图/带 CORS 头的跨域图；与 <img> 同凭证上下文）
    try {
      const data2: ArrayBuffer | null = await this.fetchImageViaPage(url);
      if (data2 && data2.byteLength > 0) {
        await WebImageSaver.saveImageBytes(context_index, data2, url);
        return;
      }
      promptAction.showToast({ message: '保存失败：图片源拒绝访问（防盗链或网络受限）' });
    } catch (err) {
      const be = err as BusinessError;
      promptAction.showToast({ message: '保存失败：' + ((be && be.message) ? be.message : '未知错误') });
    }
  }

  onCtxItem(item: string): void {
    this.ctxVisible = false;
    const url = this.ctxUrl;
    if (item === '保存图片') {
      this.saveWebImage(url);
    } else if (item === '复制图片链接' || item === '复制视频链接') {
      WebImageSaver.copyText(url, '已复制链接');
    } else if (item === '其他应用打开') {
      this.openExternalApp(url);
    }
  }

  /** 是否深色渲染：强制深色开关打开 且 系统当前为深色（开关语义=深色跟随系统） */
  private isDarkModeNow(): boolean {
    return this.get_isWebDark() && this.sysDark;
  }

  /** 亮度反转（HSV 的 V 取反、降饱和）：用于强制深色渲染时把浅色采样色转成深色 */
  private darkenSample(hex: string): string {
    const r = parseInt(hex.substring(1, 3), 16) / 255;
    const g = parseInt(hex.substring(3, 5), 16) / 255;
    const b = parseInt(hex.substring(5, 7), 16) / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const v = max;
    const sv = max === 0 ? 0 : (max - min) / max;
    let h = 0;
    if (max !== min) {
      const d = max - min;
      if (max === r) {
        h = (g - b) / d + (g < b ? 6 : 0);
      } else if (max === g) {
        h = (b - r) / d + 2;
      } else {
        h = (r - g) / d + 4;
      }
      h /= 6;
    }
    const v2 = 1 - v;
    const s2 = Math.min(1, sv * 0.6);
    const i = Math.floor(h * 6);
    const f = h * 6 - i;
    const p = v2 * (1 - s2);
    const q = v2 * (1 - f * s2);
    const t = v2 * (1 - (1 - f) * s2);
    let r2 = 0;
    let g2 = 0;
    let b2 = 0;
    switch (i % 6) {
      case 0: r2 = v2; g2 = t; b2 = p; break;
      case 1: r2 = q; g2 = v2; b2 = p; break;
      case 2: r2 = p; g2 = v2; b2 = t; break;
      case 3: r2 = p; g2 = q; b2 = v2; break;
      case 4: r2 = t; g2 = p; b2 = v2; break;
      default: r2 = v2; g2 = p; b2 = q; break;
    }
    const to2 = (x: number): string => {
      const n = Math.round(x * 255).toString(16);
      return n.length < 2 ? '0' + n : n;
    };
    return '#' + to2(r2) + to2(g2) + to2(b2);
  }

  /** 亮度判断：true=浅色背景（用深色图标） */
  private lumLight(hex: string): boolean {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6;
  }

  /** 系统栏样式：顶栏/底栏背景取页面采样色（全屏/非全屏均不固定），无采样时按深浅色兜底 */
  private async updateSystemBarStyle(topBg: string = '', bottomBg: string = ''): Promise<void> {
    try {
      const win = await window.getLastWindow(context_index);
      const dark = this.isDarkModeNow();
      let statusBarColor = dark ? '#FF1B1C21' : '#00000000';
      let statusContent = dark ? '#FFFFFFFF' : '#FF000000';
      let navigationBarColor = dark ? '#FF161920' : '#00000000';
      let navContent = '#FFFFFFFF';
      // 深色渲染下 DOM 采样仍是浅色主题原始色：浅色采样需反转成深色再上屏
      if (/^#[0-9a-fA-F]{6}$/.test(topBg)) {
        const effTop = dark && this.lumLight(topBg) ? this.darkenSample(topBg) : topBg;
        statusBarColor = '#FF' + effTop.substring(1);
        statusContent = this.lumLight(effTop) ? '#FF000000' : '#FFFFFFFF';
      }
      if (/^#[0-9a-fA-F]{6}$/.test(bottomBg)) {
        const effBottom = dark && this.lumLight(bottomBg) ? this.darkenSample(bottomBg) : bottomBg;
        navigationBarColor = '#FF' + effBottom.substring(1);
        navContent = this.lumLight(effBottom) ? '#FF000000' : '#FFFFFFFF';
      }
      win.setWindowSystemBarProperties({
        statusBarColor: statusBarColor,
        navigationBarColor: navigationBarColor,
        statusBarContentColor: statusContent,
        navigationBarContentColor: navContent,
        isStatusBarLightIcon: statusContent === '#FFFFFFFF'
      });
      // 避让区填充色与状态栏色保持一致（无采样时深色用顶栏色，浅色透明交给 panel_bg）
      let fillTop = '';
      if (/^#[0-9a-fA-F]{6}$/.test(topBg)) {
        fillTop = dark && this.lumLight(topBg) ? this.darkenSample(topBg) : topBg;
      } else {
        fillTop = dark ? '#1B1C21' : '';
      }
      if (fillTop !== this.topFillColor) {
        this.topFillColor = fillTop;
      }
      // 底栏抬高区填充色：与导航栏/底部采样色同一逻辑（无采样时深色用底栏色，浅色交给 panel_bg）
      let fillBottom = '';
      if (/^#[0-9a-fA-F]{6}$/.test(bottomBg)) {
        fillBottom = dark && this.lumLight(bottomBg) ? this.darkenSample(bottomBg) : bottomBg;
      } else {
        fillBottom = dark ? '#161920' : '';
      }
      if (fillBottom !== this.bottomFillColor) {
        this.bottomFillColor = fillBottom;
      }
    } catch (err) {
    }
  }

  /** 沉浸式取色：顶栏/底栏背景取页面色（不固定），图标按亮度自适应 */
  async applyImmersiveTheme(topBg: string, bottomBg: string = '', force: boolean = false): Promise<void> {
    if (!force && (!topBg || (topBg === this.lastTopBg && bottomBg === this.lastBottomBg))) {
      return;
    }
    if (topBg) {
      this.lastTopBg = topBg;
    }
    if (bottomBg) {
      this.lastBottomBg = bottomBg;
    }
    await this.updateSystemBarStyle(this.lastTopBg, this.lastBottomBg);
  }

  get_isLSRefresh() {
    if (this.isLSRefresh == 'true') {
      return true;
    } else {
      return false;
    }
  }

  get_isHideBar() {
    if (this.isHidebar == 'true') {
      return true;
    } else {
      return false;
    }
  }

  get_isHideStatus() {
    if (this.isHidestatus == 'true') {
      return true;
    } else {
      return false;
    }
  }

  get_isfull() {
    if (this.isFull == 'true') {
      return true;
    } else {
      return false;
    }
  }

  getuseragentbytype(type: string) {
    let ua: string = '';
    switch (type) {
      case 'Mobile':
        ua = ANDROID_UA; // 安卓客户端 UA
        break;
      case 'PC':
        ua = PC_UA;
        break;
      case 'custom':
        ua = this.c_pg_ua;
        break;
      default:
        ua = 'error';
        break;
    }
    return ua;
  }


  change_userAgent() {
    // 默认（Mobile）：伪装安卓客户端 UA，网页按 Android 手机环境渲染
    this.userAgent = this.getuseragentbytype(this.ua_type);
    this.controller.setCustomUserAgent(this.userAgent);
  }
}