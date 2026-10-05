/**
 * ImageViewerOverlay.ets —— 全屏黑底大图查看浮层
 * 手势数学一比一移植自 VHome ImageViewer（WeiboPura 同构）：
 *  - 双指捏合缩放（1x~4x），以双指焦点为中心换算位移，指缝间的点始终跟手；
 *  - 双击放大 2x / 再双击回位（220ms EaseOut）；
 *  - 放大态拖动平移，边界按 视口×(s-1)/2 钳制；捏合未过阈值自动收拢回 1x；
 *  - 长按唤出图片操作菜单（宿主页注入：保存/复制/分享），单击切换关闭按钮显隐。
 * 大图链路：花瓣系缩略后缀（_fw658hbdr 等）剥离优先加载原图，onError 逐级回退原 URL。
 * 图片节点常驻不重建（缩放/平移只改属性）：双击缩放不重新解码、不闪。
 */

const MAX_SCALE: number = 4;
/** 低于该倍率视为「未放大」，收拢回 1x */
const ZOOMED_THRESHOLD: number = 1.05;

@Component
export struct ImageViewerOverlay {
  /** 当前查看的图片 URL（宿主页长按菜单/查看大图入口传入） */
  @Prop viewerUrl: string = '';
  /** 顶部安全区高度（vp）：关闭按钮避让状态栏 */
  @Prop topInset: number = 0;
  onClose: () => void = (): void => { };
  /** 长按图片：宿主页唤出操作菜单，参数为当前显示分辨率的 URL（保存时存的就是看到的那张） */
  onLongPress: (url: string) => void = (_url: string): void => { };

  /** 候选源：[剥离缩略后缀的原图, 原样 URL]；onError 逐级回退 */
  @State candidates: string[] = [];
  @State curIdx: number = 0;
  @State loading: boolean = true;
  /** 缩放与平移（VHome 同构） */
  @State zoomScale: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;
  @State showClose: boolean = true;
  /** 捏合起点快照（倍率 + 平移 + 双指焦点） */
  private pinchBaseScale: number = 1;
  private pinchBasePanX: number = 0;
  private pinchBasePanY: number = 0;
  private pinchCenterX: number = 0;
  private pinchCenterY: number = 0;
  /** 拖动起点快照（累计位移差值法） */
  private panStartX: number = 0;
  private panStartY: number = 0;
  private panBaseX: number = 0;
  private panBaseY: number = 0;
  private dragReady: boolean = false;
  /** 视口尺寸（vp）：onAreaChange 实测 */
  private viewportWidth: number = 1;
  private viewportHeight: number = 1;

  aboutToAppear(): void {
    this.candidates = this.buildCandidates(this.viewerUrl);
    this.curIdx = 0;
    this.loading = this.candidates.length > 0;
    this.resetZoom();
  }

  /**
   * 花瓣系 CDN 缩略后缀剥离：<key>_fw658hbdr.jpg → <key>.jpg（原图）。
   * 站点缩略图统一带 _<字母><数字><字母> 后缀（_fw658 / _sq75 / _fw236hbdr 等），
   * 剥离即原图地址；剥离候选加载失败时 onError 回退原样 URL。
   */
  private buildCandidates(url: string): string[] {
    const out: string[] = [];
    if (!url || url.length === 0) {
      return out;
    }
    if (url.indexOf('data:image/') === 0) {
      out.push(url);
      return out;
    }
    try {
      const m: RegExpMatchArray | null =
        url.match(/^(https?:\/\/.*\/[^/?#]+?)_[a-z]{1,3}\d{2,4}[a-z]*\.(jpg|jpeg|png|webp|gif)$/i);
      if (m && m[1] && m[2]) {
        out.push(m[1] + '.' + m[2].toLowerCase());
      }
    } catch (err) {
    }
    out.push(url);
    return out;
  }

  /** 当前显示中的图片地址（长按保存/复制/分享以它为准） */
  private currentUrl(): string {
    if (this.curIdx < 0 || this.curIdx >= this.candidates.length) {
      return this.viewerUrl;
    }
    return this.candidates[this.curIdx];
  }

  private zoomed(): boolean {
    return this.zoomScale > ZOOMED_THRESHOLD;
  }

  /** 双击缩放（2x，220ms EaseOut；缩回原位平移一并归零） */
  private toggleZoom(): void {
    if (this.zoomed()) {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.zoomScale = 1;
        this.panX = 0;
        this.panY = 0;
      });
      this.dragReady = false;
    } else {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.zoomScale = 2;
        this.panX = this.clampPanX(this.panX, this.zoomScale);
        this.panY = this.clampPanY(this.panY, this.zoomScale);
      });
    }
  }

  /** 捏合起点快照（倍率 + 平移 + 双指焦点屏幕坐标） */
  private startPinch(event: GestureEvent): void {
    this.pinchBaseScale = this.zoomScale;
    this.pinchBasePanX = this.panX;
    this.pinchBasePanY = this.panY;
    this.pinchCenterX = Number(event.pinchCenterX);
    this.pinchCenterY = Number(event.pinchCenterY);
  }

  /** 捏合更新：以双指焦点为中心缩放（VHome 同款数学，跟手不漂移） */
  private updatePinch(event: GestureEvent): void {
    const rawScale: number = this.pinchBaseScale * Number(event.scale);
    const nextScale: number = Math.max(1, Math.min(MAX_SCALE, rawScale));
    const centerX: number = Number(event.pinchCenterX);
    const centerY: number = Number(event.pinchCenterY);
    const baseScale: number = Math.max(0.01, this.pinchBaseScale);
    const scaleRatio: number = nextScale / baseScale;
    const baseCenterX: number = this.viewportWidth / 2;
    const baseCenterY: number = this.viewportHeight / 2;
    const contentX: number = (this.pinchBasePanX + this.pinchCenterX - baseCenterX) / baseScale;
    const contentY: number = (this.pinchBasePanY + this.pinchCenterY - baseCenterY) / baseScale;
    const nextPanX: number = (centerX - baseCenterX) - contentX * nextScale;
    const nextPanY: number = (centerY - baseCenterY) - contentY * nextScale;
    this.zoomScale = nextScale;
    this.panX = this.clampPanX(nextPanX, nextScale);
    this.panY = this.clampPanY(nextPanY, nextScale);
  }

  /** 捏合结束：未过阈值收拢回 1x，已放大则钳制在可视范围 */
  private finishZoom(): void {
    if (this.zoomScale < ZOOMED_THRESHOLD) {
      this.zoomScale = 1;
    }
    if (this.zoomScale === 1) {
      this.panX = 0;
      this.panY = 0;
    } else {
      this.panX = this.clampPanX(this.panX, this.zoomScale);
      this.panY = this.clampPanY(this.panY, this.zoomScale);
    }
  }

  private startPan(event: GestureEvent): void {
    this.panStartX = event.offsetX;
    this.panStartY = event.offsetY;
    this.panBaseX = this.panX;
    this.panBaseY = this.panY;
    this.dragReady = this.zoomScale > ZOOMED_THRESHOLD;
  }

  private updatePan(event: GestureEvent): void {
    if (this.dragReady && this.zoomScale > ZOOMED_THRESHOLD) {
      this.panX = this.clampPanX(this.panBaseX + event.offsetX - this.panStartX, this.zoomScale);
      this.panY = this.clampPanY(this.panBaseY + event.offsetY - this.panStartY, this.zoomScale);
    }
  }

  private finishPan(): void {
    if (this.dragReady && this.zoomScale > ZOOMED_THRESHOLD) {
      this.panX = this.clampPanX(this.panX, this.zoomScale);
      this.panY = this.clampPanY(this.panY, this.zoomScale);
      this.dragReady = false;
    }
  }

  /** 平移钳制：放大 s 倍时边界 = 视口 × (s-1)/2 */
  private clampPanX(value: number, scale: number): number {
    const limit: number = Math.max(0, (this.viewportWidth * Math.max(1, scale - 1)) / 2);
    return Math.max(-limit, Math.min(limit, value));
  }

  private clampPanY(value: number, scale: number): number {
    const limit: number = Math.max(0, (this.viewportHeight * Math.max(1, scale - 1)) / 2);
    return Math.max(-limit, Math.min(limit, value));
  }

  private resetZoom(): void {
    this.zoomScale = 1;
    this.panX = 0;
    this.panY = 0;
    this.dragReady = false;
  }

  build() {
    Stack() {
      // 图片节点常驻：缩放/平移只改属性不重建节点（双击不重新解码、不闪）
      Image(this.currentUrl())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .draggable(false)
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.panX, y: this.panY })
        .onComplete((): void => {
          this.loading = false;
        })
        .onError((): void => {
          // 优先加载的原图地址失效 → 逐级回退到原样 URL
          if (this.curIdx < this.candidates.length - 1) {
            this.curIdx = this.curIdx + 1;
            this.loading = true;
          } else {
            this.loading = false;
          }
        })

      if (this.loading) {
        LoadingProgress()
          .width(44)
          .height(44)
          .color('#FFFFFF')
      }

      // 顶部关闭按钮（Transparent 放行空区，单击手势仍可穿透切换显隐）
      Row() {
        Button('✕')
          .fontSize(16)
          .fontColor(Color.White)
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .backgroundColor('#59000000')
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ top: this.topInset + 12, left: 12, right: 12 })
      .visibility(this.showClose ? Visibility.Visible : Visibility.None)
      .hitTestBehavior(HitTestMode.Transparent)

      // 手势层：双击 > 捏合 > 拖动 > 单击 > 长按（VHome 同序）
      Stack()
        .width('100%')
        .height('100%')
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 })
              .onAction((): void => {
                this.toggleZoom();
              }),
            PinchGesture({ fingers: 2, distance: 5 })
              .onActionStart((event: GestureEvent): void => {
                this.startPinch(event);
              })
              .onActionUpdate((event: GestureEvent): void => {
                this.updatePinch(event);
              })
              .onActionEnd((): void => {
                this.finishZoom();
              }),
            PanGesture({ fingers: 1, direction: PanDirection.All, distance: 3 })
              .onActionStart((event: GestureEvent): void => {
                this.startPan(event);
              })
              .onActionUpdate((event: GestureEvent): void => {
                this.updatePan(event);
              })
              .onActionEnd((): void => {
                this.finishPan();
              }),
            TapGesture({ count: 1 })
              .onAction((): void => {
                this.showClose = !this.showClose;
              }),
            LongPressGesture({ fingers: 1, repeat: false, duration: 500 })
              .onAction((): void => {
                this.onLongPress(this.currentUrl());
              })
          )
        )
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .alignContent(Alignment.Center)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      // 视口实测：钳制边界用真值
      this.viewportWidth = Math.max(1, Number(newArea.width));
      this.viewportHeight = Math.max(1, Number(newArea.height));
      this.panX = this.clampPanX(this.panX, this.zoomScale);
      this.panY = this.clampPanY(this.panY, this.zoomScale);
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
