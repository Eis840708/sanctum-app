import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/models/models.dart';
import '../../../core/storage/providers.dart';
import '../../../core/storage/vault_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/widgets.dart';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';

class DiaryScreen extends ConsumerStatefulWidget {
  const DiaryScreen({super.key});
  @override
  ConsumerState<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends ConsumerState<DiaryScreen> {
  DiaryEntry? _viewing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) =>
      ref.read(diaryNotifierProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);
    if (_viewing != null) return _DetailView(entry: _viewing!, onBack: () => setState(() => _viewing = null));

    final state = ref.watch(diaryNotifierProvider);
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator(color: SanctumTheme.gold)),
      error: (e, _) => Center(child: Text('$e')),
      data: (entries) => CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(child: SectionHeader(
            title: S.diary, count: entries.length,
            action: GoldAddButton(label: S.add, onTap: () => _showAddSheet(context)),
          )),
        ),
        if (entries.isEmpty)
          SliverFillRemaining(child: EmptyState(
            emoji: '📔', title: S.noDiary, subtitle: S.noDiarySub,
            action: GoldAddButton(label: S.addEntry, onTap: () => _showAddSheet(context)),
          ))
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(delegate: SliverChildBuilderDelegate(
              (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Dismissible(
                  key: ValueKey(entries[i].id),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) {
                    HapticFeedback.mediumImpact();
                    ref.read(diaryNotifierProvider.notifier).delete(entries[i].id);
                  },
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    decoration: BoxDecoration(
                      color: SanctumTheme.red.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delete_outline,
                        color: SanctumTheme.red, size: 22),
                  ),
                  child: _DiaryCard(
                    entry: entries[i],
                    onTap: () => setState(() => _viewing = entries[i]),
                    onEdit: () => _showEditSheet(context, entries[i]),
                    onDelete: () => ref.read(diaryNotifierProvider.notifier).delete(entries[i].id),
                  ),
                ),
              ),
              childCount: entries.length,
            )),
          ),
      ]),
    );
  }

  void _showAddSheet(BuildContext context) {
    final sc = context.sc;
    final titleCtrl   = TextEditingController();
    final contentCtrl = TextEditingController();
    String selectedMood = '😊';

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: sc.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => _DiaryForm(
          title: S.addEntry,
          titleCtrl: titleCtrl, contentCtrl: contentCtrl,
          selectedMood: selectedMood,
          onMoodChange: (m) => setSt(() => selectedMood = m),
          onSave: (images) async {
            if (titleCtrl.text.isEmpty || contentCtrl.text.isEmpty) return;
            final entryId = await ref.read(diaryNotifierProvider.notifier).add(
              title: titleCtrl.text, content: contentCtrl.text, mood: selectedMood);
            // Link images to the new entry
            if (images.isNotEmpty) {
              final imgIds = <String>[];
              for (final bytes in images) {
                imgIds.add(await vaultService.addDiaryImage(bytes));
              }
              await vaultService.setDiaryImageIds(entryId, imgIds);
            }
            if (ctx.mounted) Navigator.pop(ctx);
          },
        ),
      ),
    );
  }

  void _showEditSheet(BuildContext context, DiaryEntry entry) async {
    final sc = context.sc;
    final titleCtrl   = TextEditingController(text: entry.title);
    final content     = await vaultService.decryptDiaryContent(entry);
    final contentCtrl = TextEditingController(text: content);
    String selectedMood = entry.mood;

    // Load existing images for this entry
    final existingIds    = vaultService.getDiaryImageIds(entry.id);
    final existingImages = <Uint8List>[];
    for (final id in existingIds) {
      final b = await vaultService.getDiaryImage(id);
      if (b != null) existingImages.add(b);
    }

    if (!context.mounted) return;
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: sc.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => _DiaryForm(
          title: S.editEntry,
          titleCtrl: titleCtrl, contentCtrl: contentCtrl,
          selectedMood: selectedMood,
          initialImages: existingImages,
          onMoodChange: (m) => setSt(() => selectedMood = m),
          onSave: (images) async {
            if (titleCtrl.text.isEmpty || contentCtrl.text.isEmpty) return;
            await vaultService.updateDiaryEntry(entry,
              title: titleCtrl.text, content: contentCtrl.text, mood: selectedMood);
            // Save any newly added images (images beyond the initially loaded ones)
            final newImages = images.sublist(existingImages.length);
            if (newImages.isNotEmpty) {
              final existingImgIds = vaultService.getDiaryImageIds(entry.id);
              final newIds = <String>[];
              for (final bytes in newImages) {
                newIds.add(await vaultService.addDiaryImage(bytes));
              }
              await vaultService.setDiaryImageIds(entry.id, [...existingImgIds, ...newIds]);
            }
            ref.read(diaryNotifierProvider.notifier).load();
            if (ctx.mounted) Navigator.pop(ctx);
          },
        ),
      ),
    );
  }
}

class _DiaryForm extends StatefulWidget {
  final String title;
  final TextEditingController titleCtrl, contentCtrl;
  final String selectedMood;
  final List<Uint8List> initialImages;
  final ValueChanged<String> onMoodChange;
  final Future<void> Function(List<Uint8List> images) onSave;

  const _DiaryForm({
    required this.title, required this.titleCtrl, required this.contentCtrl,
    required this.selectedMood, required this.onMoodChange, required this.onSave,
    this.initialImages = const [],
  });

  @override
  State<_DiaryForm> createState() => _DiaryFormState();
}

class _DiaryFormState extends State<_DiaryForm> {
  final _picker = ImagePicker();
  late List<Uint8List> _images;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _images = List.from(widget.initialImages);
  }

  Future<void> _pickImage(ImageSource source) async {
    final xf = await _picker.pickImage(source: source, maxWidth: 1200, maxHeight: 1200, imageQuality: 80);
    if (xf == null) return;
    final bytes = await xf.readAsBytes();
    setState(() => _images.add(bytes));
  }

  void _showImageSourceSheet() {
    final sc = context.sc;
    showModalBottomSheet(
      context: context,
      backgroundColor: sc.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        Container(width: 36, height: 4, decoration: BoxDecoration(color: sc.border2, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 12),
        ListTile(
          leading: Container(width: 36, height: 36, decoration: BoxDecoration(color: SanctumTheme.goldDim, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.camera_alt_outlined, color: SanctumTheme.gold, size: 18)),
          title: Text(S.get('takePhoto'), style: TextStyle(color: sc.textPrimary, fontSize: 14)),
          onTap: () { Navigator.pop(ctx); _pickImage(ImageSource.camera); },
        ),
        ListTile(
          leading: Container(width: 36, height: 36, decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.photo_library_outlined, color: sc.textSecondary, size: 18)),
          title: Text(S.get('fromGallery'), style: TextStyle(color: sc.textPrimary, fontSize: 14)),
          onTap: () { Navigator.pop(ctx); _pickImage(ImageSource.gallery); },
        ),
        const SizedBox(height: 8),
      ])),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: sc.border2, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Text(widget.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: sc.textPrimary)),
        const SizedBox(height: 16),
        SanctumField(label: S.title, hint: '', controller: widget.titleCtrl),
        Text(S.mood, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        const SizedBox(height: 8),
        SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal,
          children: MoodOptions.all.map((m) => GestureDetector(
            onTap: () => widget.onMoodChange(m['emoji']!),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 8),
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: widget.selectedMood == m['emoji'] ? SanctumTheme.amberDim : sc.bg3,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: widget.selectedMood == m['emoji'] ? SanctumTheme.amber.withValues(alpha: 0.4) : sc.border),
              ),
              child: Center(child: Text(m['emoji']!, style: const TextStyle(fontSize: 22))),
            ),
          )).toList(),
        )),
        const SizedBox(height: 12),
        Text(S.content, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        const SizedBox(height: 5),
        TextFormField(
          controller: widget.contentCtrl, maxLines: 5,
          style: TextStyle(color: sc.textPrimary, fontSize: 14, height: 1.6),
          decoration: const InputDecoration(hintText: ''),
        ),
        const SizedBox(height: 12),

        // ── Image section ─────────────────────────────────────
        Row(children: [
          Text(S.get('images'), style: TextStyle(fontSize: 12, color: sc.textTertiary)),
          const Spacer(),
          GestureDetector(
            onTap: _showImageSourceSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: SanctumTheme.goldDim,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.25)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.add_photo_alternate_outlined, size: 13, color: SanctumTheme.gold),
                const SizedBox(width: 5),
                Text(S.get('attachImage'), style: const TextStyle(fontSize: 12, color: SanctumTheme.gold, fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ]),
        if (_images.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _images.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_images[i], width: 80, height: 80, fit: BoxFit.cover),
                ),
                Positioned(top: 2, right: 2, child: GestureDetector(
                  onTap: () => setState(() => _images.removeAt(i)),
                  child: Container(
                    width: 20, height: 20,
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 12, color: Colors.white),
                  ),
                )),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _saving ? null : () async {
              setState(() => _saving = true);
              await widget.onSave(_images);
              if (mounted) setState(() => _saving = false);
            },
            child: _saving
              ? SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: sc.bg))
              : Text(S.save),
          ),
        ),
      ]),
    );
  }
}

class _DiaryCard extends StatelessWidget {
  final DiaryEntry entry;
  final VoidCallback onTap, onEdit, onDelete;
  const _DiaryCard({required this.entry, required this.onTap, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return VaultCard(
      accentColor: SanctumTheme.amber, onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(entry.mood, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: sc.textPrimary)),
            Text(DateFormat('MMM d, yyyy').format(entry.createdAt), style: TextStyle(fontSize: 11, color: sc.textTertiary)),
          ])),
          GestureDetector(onTap: onEdit, child: Container(
            padding: const EdgeInsets.all(6), margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(6)),
            child: Icon(Icons.edit_outlined, size: 14, color: sc.textTertiary),
          )),
          GestureDetector(onTap: onDelete, child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(6)),
            child: Icon(Icons.delete_outline, size: 14, color: sc.textTertiary),
          )),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            Icon(Icons.lock_outline, size: 12, color: sc.textTertiary),
            const SizedBox(width: 6),
            Text(S.tapToRead, style: TextStyle(fontSize: 11, color: sc.textTertiary)),
          ]),
        ),
      ]),
    );
  }
}

class _DetailView extends ConsumerStatefulWidget {
  final DiaryEntry entry;
  final VoidCallback onBack;
  const _DetailView({required this.entry, required this.onBack});
  @override
  ConsumerState<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends ConsumerState<_DetailView> {
  String? _content;
  bool _loading = true;
  List<Uint8List> _images = [];

  @override
  void initState() { super.initState(); _decrypt(); }

  Future<void> _decrypt() async {
    final content = await vaultService.decryptDiaryContent(widget.entry);
    final ids     = vaultService.getDiaryImageIds(widget.entry.id);
    final imgs    = <Uint8List>[];
    for (final id in ids) {
      final b = await vaultService.getDiaryImage(id);
      if (b != null) imgs.add(b);
    }
    if (mounted) setState(() { _content = content; _loading = false; _images = imgs; });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final xf = await picker.pickImage(
        source: ImageSource.gallery, maxWidth: 1200, maxHeight: 1200, imageQuality: 80);
    if (xf == null || !mounted) return;
    final bytes = await xf.readAsBytes();
    final id    = await vaultService.addDiaryImage(bytes);
    final ids   = vaultService.getDiaryImageIds(widget.entry.id);
    await vaultService.setDiaryImageIds(widget.entry.id, [...ids, id]);
    if (mounted) setState(() => _images.add(bytes));
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Row(children: [
          GestureDetector(onTap: widget.onBack, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(8), border: Border.all(color: sc.border)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.arrow_back, size: 14, color: sc.textSecondary),
              const SizedBox(width: 6),
              Text(S.diary, style: TextStyle(fontSize: 13, color: sc.textSecondary)),
            ]),
          )),
          const Spacer(),
          Text(widget.entry.mood, style: const TextStyle(fontSize: 24)),
        ]),
      )),
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverToBoxAdapter(child: Container(
          decoration: BoxDecoration(color: sc.bg2, borderRadius: BorderRadius.circular(14), border: Border.all(color: sc.border)),
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.entry.title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: sc.textPrimary)),
            const SizedBox(height: 4),
            Text(DateFormat('EEEE, MMMM d yyyy').format(widget.entry.createdAt),
                style: TextStyle(fontSize: 12, color: sc.textTertiary)),
            Divider(height: 24, color: sc.border),
            if (_loading) const Center(child: CircularProgressIndicator(color: SanctumTheme.gold))
            else Text(_content ?? '', style: TextStyle(fontSize: 15, color: sc.textSecondary, height: 1.8)),
            if (!_loading && _images.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _images.map((b) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(b, width: 96, height: 96, fit: BoxFit.cover),
                )).toList(),
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 16, color: SanctumTheme.gold),
              label: Text(S.get('attachImage'), style: const TextStyle(fontSize: 12, color: SanctumTheme.gold)),
            ),
          ]),
        )),
      ),
    ]);
  }
}
