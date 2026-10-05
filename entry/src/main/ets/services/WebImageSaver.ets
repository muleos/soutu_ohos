/**
 * WebImageSaver.ets
 * 网页图片保存至图库 / 链接复制（移植自 aira-browser WebImageContextActionService 的精简实现）
 *
 * 两段式 API（v1.1.3 重构）：
 *  - fetchImageEx：原生取图，Referer 多策略重试（页面 URL → 空 → 图片自身 origin），
 *    覆盖常见防盗链配置（只允许同域 Referer 或允许空 Referer 的源站）
 *  - saveImageBytes：字节落图库（安全控件弹窗优先，失败回退系统保存选择器）
 * 全链路 hilog 诊断（TAG: web-savePic），真机排查用 `hdc shell hilog | grep web-savePic`
 */
import { http } from '@kit.NetworkKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const MAX_BYTES: number = 30 * 1024 * 1024;
const TAG: string = 'web-savePic';

export class WebImageSaver {

  /**
   * 原生直取图片：Referer 多策略重试。
   * 策略顺序：页面 URL（正常浏览上下文）→ 空（部分源站"允许空 Referer"）→ 图片 origin（同域 Referer 白名单）。
   * 任一策略拿到非空 2xx 响应即返回。
   */
  static async fetchImageEx(url: string, pageReferer: string, cookie: string,
    userAgent: string): Promise<ArrayBuffer> {
    const strategies: string[] = [];
    if (pageReferer) {
      strategies.push(pageReferer);
    }
    strategies.push('');
    try {
      const m: RegExpMatchArray | null = url.match(/^https?:\/\/[^/]+/);
      if (m && m[0]) {
        strategies.push(m[0] + '/');
      }
    } catch (err) {
    }
    let lastErr: Error = new Error('未知错误');
    for (const referer of strategies) {
      try {
        const data: ArrayBuffer = await WebImageSaver.fetchImage(url, referer, cookie, userAgent);
        if (data && data.byteLength > 0) {
          hilog.info(0x0000, TAG, 'fetch ok: %{public}d B, referer=%{public}s',
            data.byteLength, referer === '' ? '(empty)' : referer);
          return data;
        }
      } catch (err) {
        const be = err as BusinessError;
        lastErr = new Error((be && be.message) ? be.message : '取图失败');
        hilog.warn(0x0000, TAG, 'fetch fail (referer=%{public}s): %{public}s',
          referer === '' ? '(empty)' : referer, lastErr.message);
      }
    }
    throw lastErr;
  }

  /**
   * 字节落图库：安全控件创建弹窗（免权限）优先；失败/取消回退系统保存选择器。
   * 抛出异常时由调用方负责提示（saveToGallery 包装器除外）。
   */
  static async saveImageBytes(context: common.UIAbilityContext, data: ArrayBuffer,
    url: string): Promise<void> {
    if (!data || data.byteLength === 0) {
      throw new Error('图片内容为空');
    }
    const ext: string = WebImageSaver.sniffExtension(data, url);
    const tempPath: string = await WebImageSaver.writeToCache(context, data, ext);

    try {
      // 首选：安全控件创建对话框（免权限，写完即入图库）
      const helper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      const assetUri: string = fileUri.getUriFromPath(tempPath);
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: 'Soutu_' + Date.now(),
        fileNameExtension: ext,
        photoType: photoAccessHelper.PhotoType.IMAGE
      };
      const created: string[] =
        await helper.showAssetsCreationDialog([assetUri], [config]);
      if (created && created.length > 0) {
        const targetUri: string = created[0];
        const targetFile = fileIo.openSync(targetUri, fileIo.OpenMode.READ_WRITE);
        fileIo.writeSync(targetFile.fd, new Uint8Array(data));
        fileIo.closeSync(targetFile);
        hilog.info(0x0000, TAG, 'saved via creation dialog: %{public}s', targetUri);
        promptAction.showToast({ message: '已保存到图库' });
      } else {
        hilog.info(0x0000, TAG, 'creation dialog dismissed by user');
        promptAction.showToast({ message: '已取消保存' });
      }
    } catch (dialogErr) {
      const de = dialogErr as BusinessError;
      hilog.error(0x0000, TAG, 'creation dialog error %{public}d: %{public}s，回退保存选择器',
        de.code ?? 0, (de && de.message) ? de.message : '?');
      // 回退：系统"保存图片"选择器（用户选位置后写入，同样免权限）
      try {
        const saveOptions = new picker.PhotoSaveOptions();
        saveOptions.newFileNames = ['Soutu_' + Date.now() + '.' + ext];
        const viewPicker = new picker.PhotoViewPicker();
        const uris: Array<string> = await viewPicker.save(saveOptions);
        if (uris && uris.length > 0) {
          const targetFile = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE);
          fileIo.writeSync(targetFile.fd, new Uint8Array(data));
          fileIo.closeSync(targetFile);
          hilog.info(0x0000, TAG, 'saved via picker: %{public}s', uris[0]);
          promptAction.showToast({ message: '已保存' });
        } else {
          promptAction.showToast({ message: '已取消保存' });
        }
      } catch (pickErr) {
        const pe = pickErr as BusinessError;
        hilog.error(0x0000, TAG, 'picker save error %{public}d: %{public}s',
          pe.code ?? 0, (pe && pe.message) ? pe.message : '?');
        throw new Error((pe && pe.message) ? pe.message : '写入图库失败');
      }
    }
  }

  /** 兼容旧调用：直取 + 保存一体（内部仍走 fetchImageEx 单 Referer 策略） */
  static async saveToGallery(context: common.UIAbilityContext, url: string,
    referer: string, cookie: string, userAgent: string): Promise<void> {
    try {
      const data: ArrayBuffer = await WebImageSaver.fetchImageEx(url, referer, cookie, userAgent);
      await WebImageSaver.saveImageBytes(context, data, url);
    } catch (err) {
      const be = err as BusinessError;
      const msg: string = (be && be.message) ? be.message : '图片无法获取';
      hilog.error(0x0000, TAG, 'saveToGallery fail: %{public}s', msg);
      promptAction.showToast({ message: '保存失败：' + msg });
    }
  }

  /** 复制文本（图片链接/视频链接） */
  static copyText(text: string, tip: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: tip });
    } catch (err) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  static async fetchImage(url: string, referer: string,
    cookie: string, userAgent: string): Promise<ArrayBuffer> {
    const httpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {};
      if (userAgent) {
        header['User-Agent'] = userAgent;
      }
      if (referer) {
        header['Referer'] = referer;
      }
      if (cookie) {
        header['Cookie'] = cookie;
      }
      header['Accept'] = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 20000,
        maxLimit: MAX_BYTES / 1024
      });
      hilog.info(0x0000, TAG, 'HTTP %{public}d, %{public}s', resp.responseCode, url.substring(0, 120));
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error('HTTP ' + resp.responseCode);
      }
      return resp.result as ArrayBuffer;
    } finally {
      httpRequest.destroy();
    }
  }

  private static sniffExtension(data: ArrayBuffer, url: string): string {
    try {
      const bytes = new Uint8Array(data.slice(0, 16));
      if (bytes.length >= 4) {
        if (bytes[0] === 0xFF && bytes[1] === 0xD8) { return 'jpg'; }
        if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) { return 'png'; }
        if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) { return 'gif'; }
        if (bytes[0] === 0x52 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42) { return 'webp'; }
      }
    } catch (err) { }
    const lower = url.toLowerCase();
    if (lower.indexOf('.png') > 0) { return 'png'; }
    if (lower.indexOf('.gif') > 0) { return 'gif'; }
    if (lower.indexOf('.webp') > 0) { return 'webp'; }
    if (lower.indexOf('.bmp') > 0) { return 'bmp'; }
    return 'jpg';
  }

  private static async writeToCache(context: common.UIAbilityContext,
    data: ArrayBuffer, ext: string): Promise<string> {
    const dir: string = context.cacheDir + '/web_images';
    try {
      fileIo.mkdirSync(dir, true);
    } catch (err) { }
    const path: string = dir + '/stq_' + Date.now() + '.' + ext;
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, new Uint8Array(data));
    fileIo.closeSync(file);
    return path;
  }
}
