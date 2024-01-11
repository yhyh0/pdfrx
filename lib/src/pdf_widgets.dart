// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';
import 'package:synchronized/extension.dart';
import 'package:vector_math/vector_math_64.dart' as vec;

import 'interactive_viewer.dart' as iv;
import 'pdf_api.dart';
import 'pdf_document_store.dart';
import 'pdf_viewer_params.dart';

/// A widget to display PDF document.
class PdfViewer extends StatefulWidget {
  const PdfViewer({
    required this.documentRef,
    super.key,
    this.controller,
    this.params = const PdfViewerParams(),
    this.initialPageNumber = 1,
  });

  PdfViewer.asset(
    String name, {
    Key? key,
    String? password,
    PdfViewerController? controller,
    PdfViewerParams displayParams = const PdfViewerParams(),
    int initialPageNumber = 1,
    PdfDocumentStore? store,
  }) : this(
          key: key,
          documentRef: (store ?? PdfDocumentStore.defaultStore).load(
            '##PdfViewer:asset:$name',
            documentLoader: (_) =>
                PdfDocument.openAsset(name, password: password),
          ),
          controller: controller,
          params: displayParams,
          initialPageNumber: initialPageNumber,
        );

  PdfViewer.file(
    String path, {
    Key? key,
    String? password,
    PdfViewerController? controller,
    PdfViewerParams displayParams = const PdfViewerParams(),
    int initialPageNumber = 1,
    PdfDocumentStore? store,
  }) : this(
          key: key,
          documentRef: (store ?? PdfDocumentStore.defaultStore).load(
            '##PdfViewer:file:$path',
            documentLoader: (_) =>
                PdfDocument.openFile(path, password: password),
          ),
          controller: controller,
          params: displayParams,
          initialPageNumber: initialPageNumber,
        );

  PdfViewer.uri(
    Uri uri, {
    Key? key,
    String? password,
    PdfViewerController? controller,
    PdfViewerParams displayParams = const PdfViewerParams(),
    int initialPageNumber = 1,
    PdfDocumentStore? store,
  }) : this(
          key: key,
          documentRef: (store ?? PdfDocumentStore.defaultStore).load(
            '##PdfViewer:uri:$uri',
            documentLoader: (progressCallback) => PdfDocument.openUri(
              uri,
              password: password,
              progressCallback: progressCallback,
            ),
          ),
          controller: controller,
          params: displayParams,
          initialPageNumber: initialPageNumber,
        );

  PdfViewer.data(
    Uint8List bytes, {
    Key? key,
    String? password,
    String? sourceName,
    PdfViewerController? controller,
    PdfViewerParams displayParams = const PdfViewerParams(),
    int initialPageNumber = 1,
    PdfDocumentStore? store,
  }) : this(
          key: key,
          documentRef: (store ?? PdfDocumentStore.defaultStore).load(
            '##PdfViewer:data:${sourceName ?? bytes.hashCode}',
            documentLoader: (_) => PdfDocument.openData(bytes,
                password: password, sourceName: sourceName),
          ),
          controller: controller,
          params: displayParams,
          initialPageNumber: initialPageNumber,
        );

  PdfViewer.custom({
    required FutureOr<int> Function(Uint8List buffer, int position, int size)
        read,
    required int fileSize,
    required String sourceName,
    String? password,
    Key? key,
    PdfViewerController? controller,
    PdfViewerParams displayParams = const PdfViewerParams(),
    int initialPageNumber = 1,
    PdfDocumentStore? store,
  }) : this(
          key: key,
          documentRef: (store ?? PdfDocumentStore.defaultStore).load(
            '##PdfViewer:custom:$sourceName',
            documentLoader: (_) => PdfDocument.openCustom(
                read: read,
                fileSize: fileSize,
                sourceName: sourceName,
                password: password),
          ),
          controller: controller,
          params: displayParams,
          initialPageNumber: initialPageNumber,
        );
  final PdfDocumentRef documentRef;

  /// Controller to control the viewer.
  final PdfViewerController? controller;

  /// Parameters to customize the display of the PDF document.
  final PdfViewerParams params;

  /// Page number to show initially.
  final int initialPageNumber;

  @override
  State<PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<PdfViewer>
    with SingleTickerProviderStateMixin {
  late final AnimationController animController;
  PdfViewerController? _controller;
  PdfDocument? _document;
  PdfPageLayout? _layout;
  Size? _viewSize;
  EdgeInsets _boundaryMargin = EdgeInsets.zero;
  double? _coverScale;
  double? _alternativeFitScale;
  int? _pageNumber;
  bool _initialized = false;
  final List<double> _zoomStops = [1.0];

  final _realSized = <int, ({ui.Image image, double scale})>{};
  final _pageTexts = <int, PdfPageText>{};

  final _stream = BehaviorSubject<Matrix4>();

  @override
  void initState() {
    super.initState();
    animController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _widgetUpdated(null);
  }

  @override
  void didUpdateWidget(covariant PdfViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _widgetUpdated(oldWidget);
  }

  Future<void> _widgetUpdated(PdfViewer? oldWidget) async {
    if (widget == oldWidget) {
      return;
    }

    if (oldWidget?.documentRef.sourceName == widget.documentRef.sourceName) {
      if (widget.params.doChangesRequireReload(oldWidget?.params)) {
        if (widget.params.annotationRenderingMode !=
            oldWidget?.params.annotationRenderingMode) {
          _realSized.clear();
        }
        _relayoutPages();

        if (mounted) {
          setState(() {});
        }
      }
      return;
    }

    oldWidget?.documentRef.removeListener(_onDocumentChanged);
    widget.documentRef.addListener(_onDocumentChanged);
    _onDocumentChanged();
  }

  void _relayout() {
    _relayoutPages();
    _realSized.clear();
    if (mounted) {
      setState(() {});
    }
  }

  void _onDocumentChanged() async {
    _layout = null;

    _realSized.clear();
    _pageTexts.clear();
    _pageNumber = null;
    _initialized = false;
    _controller?.removeListener(_onMatrixChanged);
    _controller?._attach(null);

    final document = widget.documentRef.document;
    if (document == null) {
      _document = null;
      if (mounted) {
        setState(() {});
      }
      return;
    }

    _document = document;

    _relayoutPages();

    _controller ??= widget.controller ?? PdfViewerController();
    _controller!._attach(this);
    _controller!.addListener(_onMatrixChanged);

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _cancelAllPendingRenderings();
    animController.dispose();
    widget.documentRef.removeListener(_onDocumentChanged);
    _realSized.clear();
    _pageTexts.clear();
    _controller!.removeListener(_onMatrixChanged);
    _controller!._attach(null);
    super.dispose();
  }

  void _onMatrixChanged() {
    _stream.add(_controller!.value);
  }

  @override
  Widget build(BuildContext context) {
    if (_document == null) {
      return widget.params.loadingBannerBuilder?.call(
              context,
              widget.documentRef.bytesDownloaded,
              widget.documentRef.totalBytes) ??
          Container();
    }
    return LayoutBuilder(builder: (context, constraints) {
      if (_calcViewSizeAndCoverScale(
          Size(constraints.maxWidth, constraints.maxHeight))) {
        if (_initialized) {
          Future.microtask(
            () {
              if (_initialized) {
                return _controller!
                    .goTo(_controller!.normalize(_controller!.value));
              }
            },
          );
        }
      }

      if (!_initialized && _layout != null) {
        _initialized = true;
        Future.microtask(
            () => _controller!.goToPage(pageNumber: widget.initialPageNumber));
      }

      return Container(
        color: widget.params.backgroundColor,
        child: Focus(
          onKey: _onKey,
          child: StreamBuilder(
              stream: _stream,
              builder: (context, snapshot) {
                _determineCurrentPage();
                _calcAlternativeFitScale();
                _calcZoomStopTable();
                return Stack(
                  children: [
                    iv.InteractiveViewer(
                      transformationController: _controller,
                      constrained: false,
                      maxScale: widget.params.maxScale,
                      minScale: _alternativeFitScale != null
                          ? _alternativeFitScale! / 2
                          : 0.1,
                      panAxis: widget.params.panAxis,
                      boundaryMargin: _boundaryMargin,
                      panEnabled: widget.params.panEnabled,
                      scaleEnabled: widget.params.scaleEnabled,
                      onInteractionEnd: widget.params.onInteractionEnd,
                      onInteractionStart: widget.params.onInteractionStart,
                      onInteractionUpdate: widget.params.onInteractionUpdate,
                      onWheelDelta: widget.params.scrollByMouseWheel != null
                          ? _onWheelDelta
                          : null,
                      // PDF pages
                      child: CustomPaint(
                        foregroundPainter:
                            _CustomPainter.fromFunction(_customPaint),
                        size: _layout!.documentSize,
                      ),
                    ),
                    ..._buildPageOverlayWidgets(),
                    if (widget.params.viewerOverlayBuilder != null)
                      ...widget.params.viewerOverlayBuilder!(
                          context, _controller!.viewSize)
                  ],
                );
              }),
        ),
      );
    });
  }

  int? _gotoTargetPageNumber;

  KeyEventResult _onKey(FocusNode node, RawKeyEvent event) {
    final isDown = event is RawKeyDownEvent;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.pageUp:
        if (isDown) {
          _goToPage((_gotoTargetPageNumber ?? _pageNumber!) - 1);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        if (isDown) {
          _goToPage((_gotoTargetPageNumber ?? _pageNumber!) + 1);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        if (isDown) {
          _goToPage(1);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        if (isDown) {
          _goToPage(_document!.pages.length);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.equal:
        if (isDown && event.isCommandKeyPressed) {
          _controller!.zoomUp();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.minus:
        if (isDown && event.isCommandKeyPressed) {
          _controller!.zoomDown();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (isDown) {
          _goToManipulated(
              (m) => m.translate(0.0, -widget.params.scrollByArrowKey));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (isDown) {
          _goToManipulated(
              (m) => m.translate(0.0, widget.params.scrollByArrowKey));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        if (isDown) {
          _goToManipulated(
              (m) => m.translate(widget.params.scrollByArrowKey, 0.0));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (isDown) {
          _goToManipulated(
              (m) => m.translate(-widget.params.scrollByArrowKey, 0.0));
        }
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _goToPage(int pageNumber) async {
    _gotoTargetPageNumber = pageNumber.clamp(1, _document!.pages.length);
    await _controller!.goToPage(pageNumber: _gotoTargetPageNumber!);
  }

  Future<void> _goToManipulated(void Function(Matrix4 m) manipulate) async {
    final m = _controller!.value.clone();
    manipulate(m);
    _controller!.value = m;
  }

  bool _calcViewSizeAndCoverScale(Size viewSize) {
    if (_viewSize != viewSize) {
      _viewSize = viewSize;
      final s1 = viewSize.width / _layout!.documentSize.width;
      final s2 = viewSize.height / _layout!.documentSize.height;
      _coverScale = max(s1, s2);
      return true;
    }
    return false;
  }

  void _determineCurrentPage() {
    final visibleRect = _controller!.visibleRect;
    int? pageNumberMaxInt;
    double maxIntersection = 0;
    for (int i = 0; i < _document!.pages.length; i++) {
      final rect = _layout!.pageLayouts[i];
      final intersection = rect.intersect(visibleRect);
      if (intersection.isEmpty) continue;
      final intersectionArea = intersection.width * intersection.height;
      if (intersectionArea > maxIntersection) {
        maxIntersection = intersectionArea;
        pageNumberMaxInt = i + 1;
      }
    }
    if (_pageNumber != pageNumberMaxInt) {
      _pageNumber = pageNumberMaxInt;
      if (widget.params.onPageChanged != null) {
        Future.microtask(() => widget.params.onPageChanged?.call(_pageNumber));
      }
    }
  }

  bool _calcAlternativeFitScale() {
    if (_pageNumber != null) {
      final params = widget.params;
      final rect = _layout!.pageLayouts[_pageNumber! - 1];
      final scale = min((_viewSize!.width - params.margin) / rect.width,
          (_viewSize!.height - params.margin) / rect.height);
      final w = rect.width * scale;
      final h = rect.height * scale;
      final hm = (_viewSize!.width - w) / 2;
      final vm = (_viewSize!.height - h) / 2;
      _boundaryMargin = EdgeInsets.symmetric(horizontal: hm, vertical: vm);
      _alternativeFitScale = scale;
      return true;
    } else {
      _boundaryMargin = EdgeInsets.zero;
      _alternativeFitScale = null;
      return false;
    }
  }

  void _calcZoomStopTable() {
    _zoomStops.clear();
    double z;
    if (_alternativeFitScale != null &&
        !_areZoomsAlmostIdentical(_alternativeFitScale!, _coverScale!)) {
      if (_alternativeFitScale! < _coverScale!) {
        _zoomStops.add(_alternativeFitScale!);
        z = _coverScale!;
      } else {
        _zoomStops.add(_coverScale!);
        z = _alternativeFitScale!;
      }
    } else {
      z = _coverScale!;
    }
    while (z < PdfViewerController.maxZoom) {
      _zoomStops.add(z);
      z *= 2;
    }
  }

  double _findNextZoomStop(double zoom,
      {required bool zoomUp, bool loop = true}) {
    if (zoomUp) {
      for (final z in _zoomStops) {
        if (z > zoom && !_areZoomsAlmostIdentical(z, zoom)) return z;
      }
      if (loop) {
        return _zoomStops.first;
      } else {
        return _zoomStops.last;
      }
    } else {
      for (int i = _zoomStops.length - 1; i >= 0; i--) {
        final z = _zoomStops[i];
        if (z < zoom && !_areZoomsAlmostIdentical(z, zoom)) return z;
      }
      if (loop) {
        return _zoomStops.last;
      } else {
        return _zoomStops.first;
      }
    }
  }

  static bool _areZoomsAlmostIdentical(double z1, double z2) =>
      (z1 - z2).abs() < 0.01;

  List<Widget> _buildPageOverlayWidgets() {
    if (widget.params.pageOverlayBuilder == null) return [];
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox) return [];
    Rect? documentToRenderBox(Rect rect) {
      final tl = _controller?.documentToGlobal(rect.topLeft);
      if (tl == null) return null;
      final br = _controller?.documentToGlobal(rect.bottomRight);
      if (br == null) return null;
      return Rect.fromPoints(
          renderBox.globalToLocal(tl), renderBox.globalToLocal(br));
    }

    final widgets = <Widget>[];
    final visibleRect = _controller!.visibleRect;
    final targetRect = visibleRect.inflateHV(
        horizontal: visibleRect.width, vertical: visibleRect.height);
    for (int i = 0; i < _document!.pages.length; i++) {
      final rect = _layout!.pageLayouts[i];
      final intersection = rect.intersect(targetRect);
      if (intersection.isEmpty) continue;

      final page = _document!.pages[i];
      final rectExternal = documentToRenderBox(rect);
      if (rectExternal != null) {
        final overlay = widget.params.pageOverlayBuilder!(
          context,
          rectExternal,
          page,
        );
        if (overlay != null) {
          widgets.add(Positioned(
            left: rectExternal.left,
            top: rectExternal.top,
            width: rectExternal.width,
            height: rectExternal.height,
            child: overlay,
          ));
        }
      }
    }
    return widgets;
  }

  final _cancellationTokens = <int, List<PdfPageRenderCancellationToken>>{};

  void _addCancellationToken(
      int pageNumber, PdfPageRenderCancellationToken token) {
    var tokens = _cancellationTokens.putIfAbsent(pageNumber, () => []);
    tokens.add(token);
  }

  void _cancelPendingRenderings(int pageNumber) {
    final tokens = _cancellationTokens[pageNumber];
    if (tokens != null) {
      for (final token in tokens) {
        token.cancel();
      }
      tokens.clear();
    }
  }

  void _cancelAllPendingRenderings() {
    for (final pageNumber in _cancellationTokens.keys) {
      _cancelPendingRenderings(pageNumber);
    }
    _cancellationTokens.clear();
  }

  /// [_CustomPainter] calls the function to paint PDF pages.
  void _customPaint(ui.Canvas canvas, ui.Size size) {
    final visibleRect = _controller!.visibleRect;
    final targetRect = visibleRect.inflateHV(
        horizontal: visibleRect.width, vertical: visibleRect.height);
    final double globalScale = min(
      MediaQuery.of(context).devicePixelRatio * _controller!.currentZoom,
      300.0 / 72.0,
    );

    final unusedPageList = <int>[];
    final needRelayout = <int>[];

    for (int i = 0; i < _document!.pages.length; i++) {
      final rect = _layout!.pageLayouts[i];
      final intersection = rect.intersect(targetRect);
      if (intersection.isEmpty) {
        final page = _document!.pages[i];
        _cancelPendingRenderings(page.pageNumber);
        unusedPageList.add(i + 1);
        continue;
      }

      final page = _document!.pages[i];
      var realSize = _realSized[page.pageNumber];
      final scale = widget.params.getPageRenderingScale
              ?.call(context, page, _controller!, globalScale) ??
          globalScale;
      if (realSize == null || realSize.scale != scale) {
        if (widget.params.enableRealSizeRendering && scale > 1.0) {
          _ensureRealSizeCached(page, scale);
        }
      }

      if (realSize != null) {
        canvas.drawImageRect(
          realSize.image,
          Rect.fromLTWH(
            0,
            0,
            realSize.image.width.toDouble(),
            realSize.image.height.toDouble(),
          ),
          rect,
          Paint()..filterQuality = FilterQuality.high,
        );
      } else {
        canvas.drawRect(
            rect,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.fill);
      }
      canvas.drawRect(
          rect,
          Paint()
            ..color = Colors.black
            ..strokeWidth = 0.2
            ..style = PaintingStyle.stroke);

      if (needRelayout.isNotEmpty) {
        Future.microtask(
          () {
            _relayoutPages();
            _invalidate();
          },
        );
      }

      if (unusedPageList.isNotEmpty) {
        final currentPageNumber = _pageNumber;
        if (currentPageNumber != null && currentPageNumber > 0) {
          final currentPage = _document!.pages[currentPageNumber - 1];
          _removeSomeImagesIfImageCountExceeds(
            'realSize',
            unusedPageList,
            widget.params.maxRealSizeImageCount,
            currentPage,
            (pageNumber) {
              _realSized.remove(pageNumber);
              _pageTexts.remove(pageNumber);
            },
          );
        }
      }
    }
  }

  void _relayoutPages() {
    _layout = (widget.params.layoutPages ?? _layoutPages)(
        _document!.pages, widget.params);
  }

  static PdfPageLayout _layoutPages(
      List<PdfPage> pages, PdfViewerParams params) {
    final width =
        pages.fold(0.0, (w, p) => max(w, p.width)) + params.margin * 2;

    final pageLayout = <Rect>[];
    var y = params.margin;
    for (int i = 0; i < pages.length; i++) {
      final page = pages[i];
      final rect =
          Rect.fromLTWH((width - page.width) / 2, y, page.width, page.height);
      pageLayout.add(rect);
      y += page.height + params.margin;
    }

    return PdfPageLayout(
      pageLayouts: pageLayout,
      documentSize: Size(width, y),
    );
  }

  void _invalidate() => _stream.add(_controller!.value);

  Future<void> _ensureRealSizeCached(PdfPage page, double scale) async {
    final width = page.width * scale;
    final height = page.height * scale;
    if (width < 1 || height < 1) return;

    if (_realSized[page.pageNumber]?.scale == scale) return;
    final cancellationToken = page.createCancellationToken();
    _addCancellationToken(page.pageNumber, cancellationToken);
    await synchronized(() async {
      if (_realSized[page.pageNumber]?.scale == scale) return;
      final img = await page.render(
        fullWidth: width,
        fullHeight: height,
        backgroundColor: Colors.white,
        annotationRenderingMode: widget.params.annotationRenderingMode,
        cancellationToken: cancellationToken,
      );
      if (img == null) return;
      _realSized[page.pageNumber] =
          (image: await img.createImage(), scale: scale);
      img.dispose();
      _invalidate();
    });
  }

  void _removeSomeImagesIfImageCountExceeds(
      String label,
      List<int> pageNumbers,
      int acceptableCount,
      PdfPage currentPage,
      void Function(int pageNumber) removePage) {
    if (pageNumbers.length <= acceptableCount) return;
    double dist(int pageNumber) =>
        (_layout!.pageLayouts[pageNumber - 1].center -
                _layout!.pageLayouts[currentPage.pageNumber - 1].center)
            .distanceSquared;

    pageNumbers.sort((a, b) => dist(b).compareTo(dist(a)));
    for (final key
        in pageNumbers.sublist(0, pageNumbers.length - acceptableCount)) {
      removePage(key);
    }
  }

  Future<PdfPageText> _loadPageText(PdfPage page) => synchronized(
        () async {
          var pageText = _pageTexts[page.pageNumber];
          if (pageText == null) {
            pageText = await page.loadText();
            _pageTexts[page.pageNumber] = pageText;
          }
          return pageText;
        },
      );

  void _onWheelDelta(Offset delta) {
    final m = _controller!.value.clone();
    m.translate(
      -delta.dx * widget.params.scrollByMouseWheel!,
      -delta.dy * widget.params.scrollByMouseWheel!,
    );
    _controller!.value = m;
  }
}

class PdfPageLayout {
  PdfPageLayout({required this.pageLayouts, required this.documentSize});
  final List<Rect> pageLayouts;
  final Size documentSize;
}

class PdfViewerController extends TransformationController {
  _PdfViewerState? _state;
  Animation<Matrix4>? _animGoTo;

  static const maxZoom = 8.0;

  Size get documentSize => _state!._layout!.documentSize;
  Size get viewSize => _state!._viewSize!;
  double get coverScale => _state!._coverScale!;
  double? get alternativeFitScale => _state!._alternativeFitScale;
  double get minScale => alternativeFitScale == null
      ? coverScale
      : min(coverScale, alternativeFitScale!);
  AnimationController get _animController => _state!.animController;
  Rect get visibleRect => value.calcVisibleRect(viewSize);

  List<PdfPage> get pages => _state!._document!.pages;

  bool get isLoaded => _state?._document?.pages != null;

  /// The current page number if available.
  int? get pageNumber => _state?._pageNumber;

  void _attach(_PdfViewerState? state) {
    _state = state;
  }

  @override
  set value(Matrix4 newValue) {
    super.value = normalize(newValue);
  }

  Matrix4 normalize(Matrix4 newValue) {
    _state!._calcViewSizeAndCoverScale(viewSize);

    final position = newValue.calcPosition(viewSize);

    final params = _state!.widget.params;

    final newZoom = params.boundaryMargin != null
        ? newValue.zoom
        : max(newValue.zoom, minScale);
    final hw = viewSize.width / 2 / newZoom;
    final hh = viewSize.height / 2 / newZoom;
    final x = position.dx.range(hw, documentSize.width - hw);
    final y = position.dy.range(hh, documentSize.height - hh);

    return calcMatrixFor(Offset(x, y), zoom: newZoom);
  }

  double getNextZoom({bool loop = true}) =>
      _state!._findNextZoomStop(currentZoom, zoomUp: true, loop: loop);
  double getPreviousZoom({bool loop = true}) =>
      _state!._findNextZoomStop(currentZoom, zoomUp: false, loop: loop);

  void notifyFirstChange(void Function() onFirstChange) {
    void handler() {
      removeListener(handler);
      onFirstChange();
    }

    addListener(handler);
  }

  /// Forcibly relayout the pages.
  void relayout() => _state!._relayout();

  int _animationResettingGuard = 0;

  /// Go to the specified page. [anchor] specifies how the page is positioned if the page is larger than the view.
  Future<void> goToPage(
      {required int pageNumber, PdfPageAnchor? anchor}) async {
    await goToArea(
        rect: _state!._layout!.pageLayouts[pageNumber - 1]
            .inflate(_state!.widget.params.margin),
        anchor: anchor);
  }

  /// Go to the specified area. [anchor] specifies how the page is positioned if the page is larger than the view.
  Future<void> goToArea({required Rect rect, PdfPageAnchor? anchor}) async {
    anchor ??= _state!.widget.params.pageAnchor;
    if (anchor != PdfPageAnchor.all) {
      final vRatio = viewSize.aspectRatio;
      final dRatio = documentSize.aspectRatio;
      if (vRatio > dRatio) {
        final yAnchor = anchor.index ~/ 3;
        switch (yAnchor) {
          case 0:
            rect = Rect.fromLTRB(rect.left, rect.top, rect.right,
                rect.top + rect.width / vRatio);
            break;
          case 1:
            rect = Rect.fromCenter(
                center: rect.center,
                width: viewSize.width,
                height: viewSize.height);
            break;
          case 2:
            rect = Rect.fromLTRB(rect.left, rect.bottom - rect.width / vRatio,
                rect.right, rect.bottom);
            break;
        }
      } else {
        final xAnchor = anchor.index % 3;
        switch (xAnchor) {
          case 0:
            rect = Rect.fromLTRB(rect.left, rect.top,
                rect.left + rect.height * vRatio, rect.bottom);
            break;
          case 1:
            rect = Rect.fromCenter(
                center: rect.center,
                width: viewSize.width,
                height: viewSize.height);
            break;
          case 2:
            rect = Rect.fromLTRB(rect.right - rect.height * vRatio, rect.top,
                rect.right, rect.bottom);
            break;
        }
      }
    }
    await goTo(calcMatrixForRect(rect));
  }

  /// Go to the specified position by the matrix.
  Future<void> goTo(
    Matrix4? destination, {
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    void update() {
      if (_animationResettingGuard != 0) return;
      value = _animGoTo!.value;
    }

    try {
      if (destination == null) return; // do nothing
      _animationResettingGuard++;
      _animController.reset();
      _animationResettingGuard--;
      _animGoTo = Matrix4Tween(begin: value, end: normalize(destination))
          .animate(_animController);
      _animGoTo!.addListener(update);
      await _animController
          .animateTo(1.0, duration: duration, curve: Curves.easeInOut)
          .orCancel;
    } on TickerCanceled {
      // expected
    } finally {
      _animGoTo!.removeListener(update);
    }
  }

  Future<void> ensureVisible(
    Rect rect, {
    Duration duration = const Duration(milliseconds: 200),
    double margin = 0,
  }) async {
    final restrictedRect = value.calcVisibleRect(viewSize, margin: margin);
    if (restrictedRect.containsRect(rect)) return;
    if (rect.width <= restrictedRect.width &&
        rect.height < restrictedRect.height) {
      final intRect = Rect.fromLTWH(
        rect.left < restrictedRect.left
            ? rect.left
            : rect.right < restrictedRect.right
                ? restrictedRect.left
                : restrictedRect.left + rect.right - restrictedRect.right,
        rect.top < restrictedRect.top
            ? rect.top
            : rect.bottom < restrictedRect.bottom
                ? restrictedRect.top
                : restrictedRect.top + rect.bottom - restrictedRect.bottom,
        restrictedRect.width,
        restrictedRect.height,
      );
      final newRect = intRect.inflate(margin / currentZoom);
      await goTo(
        calcMatrixForRect(newRect),
        duration: duration,
      );
      return;
    }
    await goTo(
      calcMatrixForRect(rect),
      duration: duration,
    );
  }

  Matrix4 calcMatrixFor(Offset position, {double? zoom}) {
    zoom ??= currentZoom;

    final hw = viewSize.width / 2;
    final hh = viewSize.height / 2;

    return Matrix4.compose(
        vec.Vector3(
          -position.dx * zoom + hw,
          -position.dy * zoom + hh,
          0,
        ),
        vec.Quaternion.identity(),
        vec.Vector3(zoom, zoom, 1));
  }

  Offset get centerPosition => value.calcPosition(viewSize);

  Matrix4 calcMatrixForRect(Rect rect, {double? zoomMax, double? margin}) {
    margin ??= 0;
    var zoom = min((viewSize.width - margin * 2) / rect.width,
        (viewSize.height - margin * 2) / rect.height);
    if (zoomMax != null && zoom > zoomMax) zoom = zoomMax;
    return calcMatrixFor(rect.center, zoom: zoom);
  }

  double get currentZoom => value.zoom;

  Future<void> setZoom(
    Offset position,
    double zoom,
  ) async {
    goTo(calcMatrixFor(position, zoom: zoom));
  }

  Future<void> zoomUp({
    bool loop = false,
    Offset? zoomCenter,
  }) async {
    await setZoom(zoomCenter ?? centerPosition, getNextZoom(loop: loop));
  }

  Future<void> zoomDown({
    bool loop = false,
    Offset? zoomCenter,
  }) async {
    await setZoom(zoomCenter ?? centerPosition, getPreviousZoom(loop: loop));
  }

  RenderBox? get renderBox {
    final renderBox = _state!.context.findRenderObject();
    if (renderBox is! RenderBox) return null;
    return renderBox;
  }

  /// Converts the global position to the local position in the widget.
  Offset? globalToLocal(Offset global) {
    final renderBox = this.renderBox;
    if (renderBox == null) return null;
    return renderBox.globalToLocal(global);
  }

  /// Converts the local position to the global position in the widget.
  Offset? localToGlobal(Offset local) {
    final renderBox = this.renderBox;
    if (renderBox == null) return null;
    return renderBox.localToGlobal(local);
  }

  /// Converts the global position to the local position in the PDF document structure.
  Offset? globalToDocument(Offset global) {
    final ratio = 1 / currentZoom;
    return globalToLocal(global)
        ?.translate(-value.xZoomed, -value.yZoomed)
        .scale(ratio, ratio);
  }

  /// Converts the local position in the PDF document structure to the global position.
  Offset? documentToGlobal(Offset document) => localToGlobal(document
      .scale(currentZoom, currentZoom)
      .translate(value.xZoomed, value.yZoomed));
}

extension Matrix4Ext on Matrix4 {
  /// Zoom ratio of the matrix.
  double get zoom => storage[0];

  /// X position of the matrix.
  double get xZoomed => storage[12];

  /// X position of the matrix.
  set xZoomed(double value) => storage[12] = value;

  /// Y position of the matrix.
  double get yZoomed => storage[13];

  /// Y position of the matrix.
  set yZoomed(double value) => storage[13] = value;

  double get x => xZoomed / zoom;

  set x(double value) => xZoomed = value * zoom;

  double get y => yZoomed / zoom;

  set y(double value) => yZoomed = value * zoom;

  Offset calcPosition(Size viewSize) =>
      Offset((viewSize.width / 2 - xZoomed), (viewSize.height / 2 - yZoomed)) /
      zoom;

  Rect calcVisibleRect(Size viewSize, {double margin = 0}) => Rect.fromCenter(
      center: calcPosition(viewSize),
      width: (viewSize.width - margin * 2) / zoom,
      height: (viewSize.height - margin * 2) / zoom);
}

extension RangeDouble<T extends num> on T {
  /// Identical to [num.clamp] but it does nothing if [a] is larger or equal to [b].
  T range(T a, T b) => a < b ? clamp(a, b) as T : (a + b) / 2 as T;
}

extension RectExt on Rect {
  Rect operator *(double operand) => Rect.fromLTRB(
      left * operand, top * operand, right * operand, bottom * operand);
  Rect operator /(double operand) => Rect.fromLTRB(
      left / operand, top / operand, right / operand, bottom / operand);

  bool containsRect(Rect other) =>
      contains(other.topLeft) && contains(other.bottomRight);

  Rect inflateHV({required double horizontal, required double vertical}) =>
      Rect.fromLTRB(
        left - horizontal,
        top - vertical,
        right + horizontal,
        bottom + vertical,
      );
}

/// Create a [CustomPainter] from a paint function.
class _CustomPainter extends CustomPainter {
  /// Create a [CustomPainter] from a paint function.
  const _CustomPainter.fromFunction(this.paintFunction);
  final void Function(ui.Canvas canvas, ui.Size size) paintFunction;
  @override
  void paint(ui.Canvas canvas, ui.Size size) => paintFunction(canvas, size);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class PdfPageTextSearcher {
  PdfPageTextSearcher._(this._state);
  final _PdfViewerState _state;

  Stream<PdfTextSearchResult> search(RegExp pattern) async* {
    final pages = _state._document!.pages;
    for (int i = 0; i < pages.length; i++) {
      final page = pages[i];
      final pageText = await _state._loadPageText(page);
      final matches = pattern.allMatches(pageText.fullText);
      for (final match in matches) {
        yield PdfTextSearchResult.fromTextRange(
            pageText, match.start, match.end);
      }
    }
  }
}

class PdfTextSearchResult {
  PdfTextSearchResult(this.fragments, this.start, this.end, this.bounds);

  final List<PdfPageTextFragment> fragments;
  final int start;
  final int end;
  final PdfRect bounds;

  static PdfTextSearchResult fromTextRange(PdfPageText pageText, int a, int b) {
    // basically a should be less than or equal to b, but we anyway swap them if not
    if (a > b) {
      final temp = a;
      a = b;
      b = temp;
    }
    final s = pageText.getFragmentIndexForTextIndex(a);
    final e = pageText.getFragmentIndexForTextIndex(b);
    final sf = pageText.fragments[s];
    if (s == e) {
      if (sf.charRects == null) {
        return PdfTextSearchResult(
          pageText.fragments.sublist(s, e),
          a - sf.index,
          b - sf.index,
          sf.bounds,
        );
      } else {
        return PdfTextSearchResult(
          pageText.fragments.sublist(s, e),
          a - sf.index,
          b - sf.index,
          sf.charRects!.skip(a - sf.index).take(b - a).boundingRect(),
        );
      }
    }

    var bounds = sf.charRects != null
        ? sf.charRects!.skip(a - sf.index).boundingRect()
        : sf.bounds;
    for (int i = s + 1; i < e; i++) {
      bounds = bounds.merge(pageText.fragments[i].bounds);
    }
    final ef = pageText.fragments[e];
    bounds = bounds.merge(ef.charRects != null
        ? ef.charRects!.take(b - ef.index).boundingRect()
        : ef.bounds);

    return PdfTextSearchResult(
        pageText.fragments.sublist(s, e), s - sf.index, e - ef.index, bounds);
  }
}

extension RawKeyEventExt on RawKeyEvent {
  /// Key pressing state of ⌘ or Control depending on the platform.
  bool get isCommandKeyPressed =>
      Platform.isMacOS || Platform.isIOS ? isMetaPressed : isControlPressed;
}
