import 'kinds.dart';

/// The namespaces the system writes tags into on its own, derived from
/// metadata rather than typed by a person. User tags may claim any other
/// namespace — that set is open by design; this one is not.
enum TagNamespace {
  /// The container format: `format/mp3`, `format/flac`.
  format('format'),

  /// The media kind: `kind/audio`, `kind/video`.
  kind('kind');

  const TagNamespace(this.id);

  /// The namespace as it appears in a tag's canonical form.
  final String id;

  /// A tag in this namespace: `TagNamespace.format.tag('flac')`.
  Tag tag(String name) => Tag(id, name);
}

/// One tag: a namespace and a name, `namespace/name` in canonical form.
///
/// Tags apply to every media type. Automatic ones come from
/// [TagNamespace]; anything else is a person's own vocabulary.
class Tag {
  const Tag(this.namespace, this.name);

  /// A [MediaKind]'s automatic tag: `kind/audio`.
  Tag.ofKind(MediaKind kind) : this(TagNamespace.kind.id, kind.name);

  /// A container format's automatic tag: `format/mp3`.
  Tag.ofFormat(String format)
    : this(TagNamespace.format.id, format.toLowerCase());

  /// Parses the canonical `namespace/name` form. A bare word is a tag in
  /// the empty namespace — legal, but nothing automatic lives there.
  factory Tag.parse(String canonical) {
    final slash = canonical.indexOf('/');
    if (slash < 0) return Tag('', canonical);
    return Tag(canonical.substring(0, slash), canonical.substring(slash + 1));
  }

  final String namespace;
  final String name;

  /// The `namespace/name` form the outline speaks in.
  String get canonical => namespace.isEmpty ? name : '$namespace/$name';

  @override
  bool operator ==(Object other) =>
      other is Tag && other.namespace == namespace && other.name == name;

  @override
  int get hashCode => Object.hash(namespace, name);

  @override
  String toString() => 'Tag($canonical)';
}
