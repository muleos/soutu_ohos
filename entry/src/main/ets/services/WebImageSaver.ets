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
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';

const MAX_BYTES: number = 30 * 1024 * 1024;
const TAG: string = 'web-savePic';

export class WebImageSaver {

  /**
   * 原生直取图片：URL 候选 × Referer 策略 组合重试，逐次校验图片魔数。
   *
   * Referer 策略顺序（关键）：空 Referer 排第一 —— 搜图神器的 HTML 声明
   * `<meta name="referrer" content="no-referrer">`，WebView 显示图片时不带 Referer；
   * 花瓣等源站对"带非白名单 Referer"的请求一律 567/403 拒绝，空 Referer 才放行
   * （实测：gd-hbimg.huaban.com 空 Referer 200/1.09MB，带页面 Referer 567）。
   *
   * URL 候选：原 URL + 花瓣 edge 域回退 —— 站点自身在 gd-hbimg-edge/gd-hbimg 两域间
   * 改写（replaceHuabanUrlDomain/picAddWatermark），edge 域签名失效时主域往往仍可用。
   */
  static async fetchImageEx(url: string, pageReferer: string, cookie: string,
    userAgent: string): Promise<ArrayBuffer> {
    // data: URL 直接解码（内联图片，无网络请求）
    if (url.trim().toLowerCase().indexOf('data:image/') === 0) {
      const comma: number = url.indexOf(',');
      if (comma > 0 && url.substring(0, comma).toLowerCase().indexOf('base64') >= 0) {
        try {
          const helper = new util.Base64Helper();
          const u8: Uint8Array = helper.decodeSync(url.substring(comma + 1));
          const buf: ArrayBuffer = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
          if (WebImageSaver.isLikelyImage(buf)) {
            return buf;
          }
        } catch (err) {
        }
      }
      throw new Error('无法解析内联图片');
    }
    // 1) URL 候选
    const urls: string[] = [url];
    try {
      const m: RegExpMatchArray | null = url.match(/^(https?:\/\/)gd-hbimg-edge\.huaban\.com\/(.+)$/);
      if (m) {
        urls.push(m[1] + 'gd-hbimg.huaban.com/' + m[2]);
      }
    } catch (err) {
    }
    // 2) Referer 候选：空 → 页面 URL → 图片 origin（去重保序）
    const referers: string[] = [''];
    if (pageReferer && pageReferer !== '') {
      referers.push(pageReferer);
    }
    try {
      const m2: RegExpMatchArray | null = url.match(/^https?:\/\/[^/]+/);
      if (m2 && m2[0]) {
        const originRef: string = m2[0] + '/';
        if (referers.indexOf(originRef) < 0) {
          referers.push(originRef);
        }
      }
    } catch (err) {
    }
    // 3) 组合重试
    let lastErr: Error = new Error('未知错误');
    for (const candidate of urls) {
      for (const referer of referers) {
        try {
          const data: ArrayBuffer = await WebImageSaver.fetchImage(candidate, referer, cookie, userAgent);
          if (data && data.byteLength > 0 && WebImageSaver.isLikelyImage(data)) {
            hilog.info(0x0000, TAG, 'fetch ok: %{public}d B, url=%{public}s, referer=%{public}s',
              data.byteLength, candidate.substring(0, 100),
              referer === '' ? '(empty)' : referer.substring(0, 60));
            return data;
          }
          lastErr = new Error('HTTP 2xx 但非图片内容（可能为防盗链错误页）');
        } catch (err) {
          const be = err as BusinessError;
          lastErr = new Error((be && be.message) ? be.message : '取图失败');
        }
        hilog.warn(0x0000, TAG, 'fetch fail (url=%{public}s, referer=%{public}s): %{public}s',
          candidate.substring(0, 100), referer === '' ? '(empty)' : referer.substring(0, 60),
          lastErr.message);
      }
    }
    throw lastErr;
  }

  /** 图片魔数校验（公开）：页面 fetch / WebView 下载兜底通道的字节校验入口 */
  static isImageBytes(data: ArrayBuffer): boolean {
    return WebImageSaver.isLikelyImage(data);
  }

  /** 图片魔数校验：jpg/png/gif/webp；2xx HTML 防盗链错误页在这里被拒绝 */
  private static isLikelyImage(data: ArrayBuffer): boolean {    try {
      const bytes = new Uint8Array(data.slice(0, 12));
      if (bytes.length < 4) {
        return false;
      }
      if (bytes[0] === 0xFF && bytes[1] === 0xD8) {
        return true;
      }
      if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
        return true;
      }
      if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
        return true;
      }
      if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
        bytes[3] === 0x46 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42) {
        return true;
      }
    } catch (err) {
    }
    return false;
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

  /** 复制图片本体到剪贴板（解码为 PixelMap 写入，粘到聊天输入框/备忘录即为图片） */
  static async copyImageToClipboard(data: ArrayBuffer): Promise<void> {
    if (!data || data.byteLength === 0) {
      throw new Error('图片内容为空');
    }
    const source: image.ImageSource = image.createImageSource(data);
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await source.createPixelMap();
      const clipData = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
      await pasteboard.getSystemPasteboard().setData(clipData);
      hilog.info(0x0000, TAG, 'image copied to pasteboard: %{public}d B', data.byteLength);
    } finally {
      if (pixelMap) {
        await pixelMap.release().catch((_e: Error) => { });
      }
      await source.release().catch((_e: Error) => { });
    }
  }

  /** 分享图片：字节写缓存文件 → 系统分享面板（移植自 aira-browser shareImage 方案） */
  static async shareImageFile(context: common.UIAbilityContext, data: ArrayBuffer,
    url: string): Promise<void> {
    if (!data || data.byteLength === 0) {
      throw new Error('图片内容为空');
    }
    const ext: string = WebImageSaver.sniffExtension(data, url);
    const path: string = await WebImageSaver.writeToCache(context, data, ext);
    const uri: string = fileUri.getUriFromPath(path);
    const title: string = 'Soutu_' + Date.now() + '.' + ext;
    const utd: uniformTypeDescriptor.UniformDataType =
      ext === 'png' ? uniformTypeDescriptor.UniformDataType.PNG :
        ext === 'gif' ? uniformTypeDescriptor.UniformDataType.GIF :
          (ext === 'jpg' || ext === 'jpeg') ? uniformTypeDescriptor.UniformDataType.JPEG :
            uniformTypeDescriptor.UniformDataType.IMAGE;
    const shareData = new systemShare.SharedData({
      utd: utd,
      uri: uri,
      title: title,
      label: title
    });
    const controller = new systemShare.ShareController(shareData);
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DEFAULT
    });
    hilog.info(0x0000, TAG, 'share panel opened: %{public}s (%{public}d B)', path, data.byteLength);
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

  static sniffExtension(data: ArrayBuffer, url: string): string {
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
