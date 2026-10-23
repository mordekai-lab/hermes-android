import 'package:flutter/material.dart';

/// Ephemeral activity, not an assistant message or a retained transcript row.
class ChatActivityBubble extends StatelessWidget {
  static const bubbleKey = ValueKey('chat-live-activity');
  final String label;

  const ChatActivityBubble({required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Semantics(
          liveRegion: true,
          label: label,
          excludeSemantics: true,
          child: Container(
            key: bubbleKey,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final opacity in [0.4, 0.7, 1.0])
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: opacity,
                        ),
                      ),
                      child: const SizedBox.square(dimension: 5),
                    ),
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
