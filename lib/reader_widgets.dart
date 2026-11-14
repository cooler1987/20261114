import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'models.dart';

// ────────────────── 1. 微信读书质感底部悬浮播控仓 ──────────────────
class WeReadPlayerBar extends StatelessWidget {
  final bool isWide;
  final String engineLabel;
  final String voiceName;
  final double speechRate;
  final int sleepTimeLeftSeconds;
  final bool sleepStopAfterChapter;
  final int currentIndex;
  final int totalNodes;
  final bool isPlaying;
  final bool isBuffering;
  final bool followAlong;
  final bool isDirectNetwork;

  final VoidCallback onVoiceTap;
  final VoidCallback onSpeedTap;
  final VoidCallback onSleepTimerTap;
  final ValueChanged<int> onSeek;
  final VoidCallback onOpenDrawer;
  final VoidCallback onPrev;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onToggleFollowAlong;
  final VoidCallback onExportTap;

  const WeReadPlayerBar({
    super.key,
    required this.isWide,
    required this.engineLabel,
    required this.voiceName,
    required this.speechRate,
    required this.sleepTimeLeftSeconds,
    required this.sleepStopAfterChapter,
    required this.currentIndex,
    required this.totalNodes,
    required this.isPlaying,
    required this.isBuffering,
    required this.followAlong,
    required this.isDirectNetwork,
    required this.onVoiceTap,
    required this.onSpeedTap,
    required this.onSleepTimerTap,
    required this.onSeek,
    required this.onOpenDrawer,
    required this.onPrev,
    required this.onPlayPause,
    required this.onNext,
    required this.onToggleFollowAlong,
    required this.onExportTap,
  });

  @override
  Widget build(BuildContext context) {
    final double progressFraction = (totalNodes <= 0) ? 0.0 : (currentIndex / max(1, totalNodes - 1)).clamp(0.0, 1.0);

    return Container(
      margin: EdgeInsets.symmetric(horizontal: isWide ? 28 : 12, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFBF7),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE5E2D9), width: 1),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onVoiceTap,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: const Color(0xFFF3EEE1), borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isDirectNetwork ? Icons.public : Icons.vpn_lock,
                          size: 13,
                          color: const Color(0xFFC87D2E),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            "$engineLabel·$voiceName",
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF2C3238)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFFC87D2E)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onSpeedTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(border: Border.all(color: const Color(0xFFDDD9CD)), borderRadius: BorderRadius.circular(12)),
                  child: Text("${speechRate}x", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFC87D2E))),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onSleepTimerTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (sleepTimeLeftSeconds > 0 || sleepStopAfterChapter) ? const Color(0xFFEFE7D2) : Colors.transparent,
                    border: Border.all(
                      color: (sleepTimeLeftSeconds > 0 || sleepStopAfterChapter) ? const Color(0xFFC87D2E) : const Color(0xFFDDD9CD),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.bedtime_outlined,
                        size: 13,
                        color: (sleepTimeLeftSeconds > 0 || sleepStopAfterChapter) ? const Color(0xFFC87D2E) : Colors.grey,
                      ),
                      if (sleepTimeLeftSeconds > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            "${sleepTimeLeftSeconds ~/ 60}m",
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFC87D2E)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (totalNodes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Row(
                children: [
                  Text("${currentIndex + 1}/$totalNodes", style: const TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.5,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                        activeTrackColor: const Color(0xFFC87D2E),
                        inactiveTrackColor: const Color(0xFFE0DDD5),
                        thumbColor: const Color(0xFFC87D2E),
                      ),
                      child: Slider(
                        value: progressFraction,
                        onChanged: (val) {
                          final int target = (val * (totalNodes - 1)).round();
                          onSeek(target);
                        },
                      ),
                    ),
                  ),
                  Text("${(progressFraction * 100).toStringAsFixed(1)}%", style: const TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: Icon(isWide ? Icons.menu_open : Icons.menu_book_outlined), tooltip: "目录与书架", onPressed: onOpenDrawer),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.skip_previous_rounded, size: 28), tooltip: "上一项", onPressed: onPrev),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: onPlayPause,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: const BoxDecoration(
                            color: Color(0xFFC87D2E),
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: Color(0x40C87D2E), blurRadius: 8, offset: Offset(0, 3))],
                          ),
                          child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 30),
                        ),
                        if (isPlaying && isBuffering)
                          const SizedBox(
                            width: 48,
                            height: 48,
                            child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white70),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(icon: const Icon(Icons.skip_next_rounded, size: 28), tooltip: "下一项", onPressed: onNext),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      followAlong ? Icons.vertical_align_center : Icons.vertical_align_bottom_outlined,
                      color: followAlong ? const Color(0xFFC87D2E) : Colors.grey,
                      size: 20,
                    ),
                    tooltip: followAlong ? "跟读居中: 开" : "跟读居中: 关",
                    onPressed: onToggleFollowAlong,
                  ),
                  IconButton(icon: const Icon(Icons.audio_file_outlined, color: Color(0xFFC87D2E), size: 20), tooltip: "批量导出 MP3", onPressed: onExportTap),
                ],
              )
            ],
          ),
        ],
      ),
    );
  }
}

// ────────────────── 2. 抽屉侧边栏 (目录自动定位当前章 + 书架 + 书签) ──────────────────
class ReaderSidebar extends StatefulWidget {
  final int sidebarTab;
  final bool isSelectionMode;
  final Set<String> selectedFingerprints;
  final List<BookChapter> chapters;
  final int currentIndex;
  final List<BookHistoryItem> bookList;
  final List<BookBookmark> bookmarks;

  final ValueChanged<int> onTabChanged;
  final VoidCallback onToggleSelectionMode;
  final ValueChanged<int> onChapterSelected;
  final ValueChanged<BookHistoryItem> onBookSelected;
  final ValueChanged<BookHistoryItem> onBookRelink;
  final Function(String fp, bool selected) onToggleBookSelection;
  final VoidCallback onSelectAllToggle;
  final VoidCallback onDeleteSelected;

  final ValueChanged<BookBookmark> onBookmarkSelected;
  final ValueChanged<BookBookmark> onBookmarkEdit;
  final ValueChanged<BookBookmark> onBookmarkDelete;

  const ReaderSidebar({
    super.key,
    required this.sidebarTab,
    required this.isSelectionMode,
    required this.selectedFingerprints,
    required this.chapters,
    required this.currentIndex,
    required this.bookList,
    required this.bookmarks,
    required this.onTabChanged,
    required this.onToggleSelectionMode,
    required this.onChapterSelected,
    required this.onBookSelected,
    required this.onBookRelink,
    required this.onToggleBookSelection,
    required this.onSelectAllToggle,
    required this.onDeleteSelected,
    required this.onBookmarkSelected,
    required this.onBookmarkEdit,
    required this.onBookmarkDelete,
  });

  @override
  State<ReaderSidebar> createState() => _ReaderSidebarState();
}

class _ReaderSidebarState extends State<ReaderSidebar> {
  final Set<int> _collapsedChapterIndices = {};
  final ItemScrollController _tocScrollController = ItemScrollController();

  List<int> _computeVisibleIndices() {
    final List<int> visible = [];
    int collapsedAtLevel = -1;
    for (int i = 0; i < widget.chapters.length; i++) {
      final c = widget.chapters[i];
      if (collapsedAtLevel != -1) {
        if (c.level > collapsedAtLevel) {
          continue;
        } else {
          collapsedAtLevel = -1;
        }
      }
      visible.add(i);
      if (_collapsedChapterIndices.contains(i)) {
        collapsedAtLevel = c.level;
      }
    }
    return visible;
  }

  int _findActiveDisplayIndex(List<int> visibleIndices) {
    for (int d = 0; d < visibleIndices.length; d++) {
      final origIdx = visibleIndices[d];
      final c = widget.chapters[origIdx];
      final bool isCur = widget.currentIndex >= c.paragraphIndex &&
          (origIdx + 1 >= widget.chapters.length || widget.currentIndex < widget.chapters[origIdx + 1].paragraphIndex);
      if (isCur) return d;
    }
    return 0;
  }

  void _scrollToActiveChapter() {
    if (widget.sidebarTab != 0 || widget.chapters.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tocScrollController.isAttached) return;
      final visible = _computeVisibleIndices();
      if (visible.isEmpty) return;
      final activeDisplay = _findActiveDisplayIndex(visible);
      _tocScrollController.jumpTo(index: activeDisplay, alignment: 0.35);
    });
  }

  @override
  void initState() {
    super.initState();
    _scrollToActiveChapter();
  }

  @override
  void didUpdateWidget(covariant ReaderSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sidebarTab == 0 && oldWidget.sidebarTab != 0) {
      _scrollToActiveChapter();
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleChapterIndices = _computeVisibleIndices();

    return Container(
      width: 320,
      color: const Color(0xFFF0EDE4),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      padding: EdgeInsets.zero,
                      label: const Center(child: Text("📑 目录", style: TextStyle(fontSize: 11.5))),
                      selected: widget.sidebarTab == 0,
                      selectedColor: Colors.white,
                      onSelected: (_) => widget.onTabChanged(0),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: ChoiceChip(
                      padding: EdgeInsets.zero,
                      label: const Center(child: Text("📚 书架", style: TextStyle(fontSize: 11.5))),
                      selected: widget.sidebarTab == 1,
                      selectedColor: Colors.white,
                      onSelected: (_) => widget.onTabChanged(1),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: ChoiceChip(
                      padding: EdgeInsets.zero,
                      label: Center(child: Text("🔖 书签 (${widget.bookmarks.length})", style: const TextStyle(fontSize: 11.5))),
                      selected: widget.sidebarTab == 2,
                      selectedColor: Colors.white,
                      onSelected: (_) => widget.onTabChanged(2),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.sidebarTab == 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("共 ${widget.bookList.length} 本图书", style: const TextStyle(fontSize: 12, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                      icon: Icon(widget.isSelectionMode ? Icons.close : Icons.checklist, size: 16),
                      label: Text(widget.isSelectionMode ? "退出多选" : "批量管理", style: const TextStyle(fontSize: 12)),
                      onPressed: widget.onToggleSelectionMode,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Builder(
                builder: (context) {
                  // Tab 0: 章节目录 (自动居中定位 + 双热区折叠)
                  if (widget.sidebarTab == 0) {
                    if (widget.chapters.isEmpty) {
                      return const Center(child: Text("当前图书无大纲目录", style: TextStyle(color: Colors.grey, fontSize: 13)));
                    }
                    final initialTocIdx = _findActiveDisplayIndex(visibleChapterIndices);
                    return ScrollablePositionedList.builder(
                      itemScrollController: _tocScrollController,
                      initialScrollIndex: initialTocIdx,
                      initialAlignment: 0.35,
                      itemCount: visibleChapterIndices.length,
                      itemBuilder: (ctx, displayIdx) {
                        final origIdx = visibleChapterIndices[displayIdx];
                        final c = widget.chapters[origIdx];
                        final isCur = widget.currentIndex >= c.paragraphIndex &&
                            (origIdx + 1 >= widget.chapters.length || widget.currentIndex < widget.chapters[origIdx + 1].paragraphIndex);

                        final bool hasChildren = (origIdx + 1 < widget.chapters.length) && (widget.chapters[origIdx + 1].level > c.level);
                        final bool isCollapsed = _collapsedChapterIndices.contains(origIdx);

                        final int level = c.level.clamp(0, 4);
                        final double indentPadding = 8.0 + (level * 16.0);
                        final bool isPrimary = level == 0;

                        return Container(
                          color: isCur ? const Color(0xFFE5DFC9) : Colors.transparent,
                          padding: EdgeInsets.only(left: indentPadding, right: 8),
                          child: Row(
                            children: [
                              if (hasChildren)
                                InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    setState(() {
                                      if (isCollapsed) {
                                        _collapsedChapterIndices.remove(origIdx);
                                      } else {
                                        _collapsedChapterIndices.add(origIdx);
                                      }
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(6.0),
                                    child: AnimatedRotation(
                                      turns: isCollapsed ? -0.25 : 0.0,
                                      duration: const Duration(milliseconds: 180),
                                      child: Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        size: 18,
                                        color: isCur ? const Color(0xFFC87D2E) : Colors.blueGrey,
                                      ),
                                    ),
                                  ),
                                )
                              else if (!isPrimary)
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                  child: Icon(
                                    Icons.subdirectory_arrow_right_rounded,
                                    size: 13,
                                    color: isCur ? const Color(0xFFC87D2E) : Colors.blueGrey.shade300,
                                  ),
                                )
                              else
                                const SizedBox(width: 30),
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () {
                                    Navigator.pop(context);
                                    widget.onChapterSelected(c.paragraphIndex);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                                    child: Text(
                                      c.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: isPrimary ? 13.5 : 12.5,
                                        color: isCur
                                            ? const Color(0xFFC87D2E)
                                            : (isPrimary ? const Color(0xFF2C3238) : const Color(0xFF555B61)),
                                        fontWeight: isCur ? FontWeight.bold : (isPrimary ? FontWeight.w600 : FontWeight.normal),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  }

                  // Tab 1: 个人书架
                  if (widget.sidebarTab == 1) {
                    if (widget.bookList.isEmpty) {
                      return const Center(child: Text("书架空空如也\n请在右上角导入图书", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13)));
                    }
                    return ListView.builder(
                      itemCount: widget.bookList.length,
                      itemBuilder: (ctx, idx) {
                        final item = widget.bookList[idx];
                        final isSelected = widget.selectedFingerprints.contains(item.fingerprint);
                        final bool fileExists = File(item.lastKnownPath).existsSync();
                        final sizeStr = item.fileSize > 0 ? formatFileSize(item.fileSize) : "";

                        return Card(
                          elevation: isSelected ? 2 : 0.5,
                          color: isSelected ? const Color(0xFFEFE7D2) : const Color(0xFFFCFBF7),
                          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: isSelected ? const BorderSide(color: Color(0xFFC87D2E), width: 1.5) : const BorderSide(color: Color(0xFFE9E7DE)),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              if (widget.isSelectionMode) {
                                widget.onToggleBookSelection(item.fingerprint, !isSelected);
                              } else {
                                Navigator.pop(context);
                                if (fileExists) {
                                  widget.onBookSelected(item);
                                } else {
                                  widget.onBookRelink(item);
                                }
                              }
                            },
                            onLongPress: () {
                              if (!widget.isSelectionMode) {
                                widget.onToggleSelectionMode();
                                widget.onToggleBookSelection(item.fingerprint, true);
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Row(
                                children: [
                                  if (widget.isSelectionMode) ...[
                                    Checkbox(
                                      visualDensity: VisualDensity.compact,
                                      value: isSelected,
                                      onChanged: (val) => widget.onToggleBookSelection(item.fingerprint, val == true),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.bookName,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            height: 1.25,
                                            color: fileExists ? const Color(0xFF2C3238) : Colors.redAccent,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            if (sizeStr.isNotEmpty) Text("$sizeStr · ", style: const TextStyle(fontSize: 10, color: Colors.blueGrey)),
                                            Text(
                                              "进度: ${(item.percentage * 100).toStringAsFixed(1)}%",
                                              style: const TextStyle(fontSize: 10, color: Color(0xFFC87D2E), fontWeight: FontWeight.bold),
                                            ),
                                            if (!fileExists)
                                              const Padding(
                                                padding: EdgeInsets.only(left: 6),
                                                child: Text("(未连接·点击重链)", style: TextStyle(fontSize: 10, color: Colors.redAccent)),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  }

                  // Tab 2: 精彩书签
                  if (widget.bookmarks.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          "当前图书暂无书签\n\n在正文长按或右键句子\n即可在此添加书签",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.5),
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: widget.bookmarks.length,
                    itemBuilder: (ctx, idx) {
                      final bm = widget.bookmarks[idx];
                      final dateStr = DateTime.fromMillisecondsSinceEpoch(bm.createTime).toLocal().toString().substring(5, 16);

                      return Card(
                        elevation: 0.5,
                        color: const Color(0xFFFCFBF7),
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFFE9E7DE)),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            Navigator.pop(context);
                            widget.onBookmarkSelected(bm);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.bookmark, size: 15, color: Color(0xFFC87D2E)),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        bm.chapterTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF743C00)),
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.blueGrey),
                                      tooltip: "删除书签",
                                      onPressed: () => widget.onBookmarkDelete(bm),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "“${bm.content}”",
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF2C3238), fontStyle: FontStyle.italic, height: 1.3),
                                ),
                                if (bm.note.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(color: const Color(0xFFF1ECE0), borderRadius: BorderRadius.circular(4)),
                                    child: Text(
                                      "💬 ${bm.note}",
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF5A442E)),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(dateStr, style: const TextStyle(fontSize: 10, color: Colors.blueGrey)),
                                    InkWell(
                                      onTap: () => widget.onBookmarkEdit(bm),
                                      child: const Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                        child: Row(
                                          children: [
                                            Icon(Icons.edit_note, size: 14, color: Color(0xFFC87D2E)),
                                            SizedBox(width: 2),
                                            Text("编辑备注", style: TextStyle(fontSize: 10.5, color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (widget.isSelectionMode && widget.sidebarTab == 1)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: Colors.white,
                child: Row(
                  children: [
                    Text("已选 ${widget.selectedFingerprints.length} 项", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: widget.onSelectAllToggle,
                      child: Text(widget.selectedFingerprints.length == widget.bookList.length ? "取消全选" : "全选"),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: widget.selectedFingerprints.isEmpty ? null : widget.onDeleteSelected,
                      child: const Text("删除记录"),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ────────────────── 3. 空白无书时的初始展示层 ──────────────────
class EmptyBookshelfView extends StatelessWidget {
  final List<BookHistoryItem> bookList;
  final VoidCallback onImportFile;
  final ValueChanged<String> onOpenBook;
  final ValueChanged<BookHistoryItem> onRelinkBook;

  const EmptyBookshelfView({
    super.key,
    required this.bookList,
    required this.onImportFile,
    required this.onOpenBook,
    required this.onRelinkBook,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_stories, color: Color(0xFFC87D2E), size: 24),
              label: const Text("原位打开 TXT / EPUB / MD (零拷贝)", style: TextStyle(color: Color(0xFF2C3238), fontSize: 16)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFCFBF7),
                elevation: 1,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                side: const BorderSide(color: Color(0xFFE9E7DE)),
              ),
              onPressed: onImportFile,
            ),
            if (bookList.isNotEmpty) ...[
              const SizedBox(height: 32),
              const Text("📚 最近阅读书架 (基于文件指纹原位承接):", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 14)),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 550),
                child: Card(
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: min(bookList.length, 6),
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, idx) {
                      final item = bookList[idx];
                      final bool fileExists = File(item.lastKnownPath).existsSync();
                      final sizeStr = item.fileSize > 0 ? formatFileSize(item.fileSize) : "";

                      return ListTile(
                        dense: true,
                        title: Text(
                          item.bookName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            height: 1.25,
                            color: fileExists ? const Color(0xFF2C3238) : Colors.redAccent,
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            if (sizeStr.isNotEmpty) Text("$sizeStr · ", style: const TextStyle(fontSize: 10, color: Colors.blueGrey)),
                            Text("上次读到: ${(item.percentage * 100).toStringAsFixed(1)}%", style: const TextStyle(fontSize: 10, color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                            if (!fileExists)
                              const Padding(padding: EdgeInsets.only(left: 6), child: Text("(未连接·点击重链)", style: TextStyle(fontSize: 10, color: Colors.redAccent))),
                          ],
                        ),
                        onTap: () {
                          if (fileExists) {
                            onOpenBook(item.lastKnownPath);
                          } else {
                            onRelinkBook(item);
                          }
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ────────────────── 4. MP3 导出最小化浮球徽标 ──────────────────
class MinimizedExportBadge extends StatelessWidget {
  final int done;
  final int total;
  final int elapsedSeconds;
  final VoidCallback onTap;

  const MinimizedExportBadge({
    super.key,
    required this.done,
    required this.total,
    required this.elapsedSeconds,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final String timeStr = "${elapsedSeconds ~/ 60}分${(elapsedSeconds % 60).toString().padLeft(2, '0')}秒";

    return Positioned(
      top: 12,
      left: 20,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(20),
        color: const Color(0xFFFCFBF7),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFC87D2E), width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFC87D2E))),
                const SizedBox(width: 8),
                Text("导出中: $done/$total (已耗时: $timeStr)", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF743C00))),
                const SizedBox(width: 6),
                const Icon(Icons.open_in_full, size: 14, color: Color(0xFFC87D2E)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
