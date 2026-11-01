import 'package:flutter/material.dart';

Widget buildSectionHeader(BuildContext context, String title, IconData icon) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );
}

Widget buildLabeledField(String label, Widget field) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
      ),
      const SizedBox(height: 6),
      field,
    ],
  );
}

Widget buildDoubleSlider({
  required String label,
  required double value,
  required double min,
  required double max,
  required int divisions,
  required String unit,
  required ValueChanged<double> onChanged,
  int fractionDigits = 2,
}) {
  final displayValue = fractionDigits == 0
      ? value.round().toString()
      : value.toStringAsFixed(fractionDigits);
  return Row(
    children: [
      SizedBox(
        width: 150,
        child: Text('$label: $displayValue $unit'),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: '$displayValue $unit',
          onChanged: onChanged,
        ),
      ),
    ],
  );
}
