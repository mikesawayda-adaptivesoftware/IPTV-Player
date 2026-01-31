import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/category.dart';

class CategorySidebar extends StatelessWidget {
  final List<Category> categories;
  final String? selectedCategoryId;
  final ValueChanged<String?> onCategorySelected;

  const CategorySidebar({
    super.key,
    required this.categories,
    this.selectedCategoryId,
    required this.onCategorySelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        border: Border(
          right: BorderSide(
            color: AppTheme.textMuted.withOpacity(0.1),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Categories',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          
          // Category list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                final category = categories[index];
                final isSelected = category.id == selectedCategoryId ||
                    (selectedCategoryId == null && category.id == 'all');
                
                return _CategoryTile(
                  category: category,
                  isSelected: isSelected,
                  onTap: () => onCategorySelected(category.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final Category category;
  final bool isSelected;
  final VoidCallback onTap;

  const _CategoryTile({
    required this.category,
    required this.isSelected,
    required this.onTap,
  });

  IconData get _icon {
    final name = category.name.toLowerCase();
    if (category.id == 'all') return Icons.grid_view;
    if (category.id == 'favorites') return Icons.favorite;
    if (category.id == 'recent') return Icons.history;
    if (name.contains('sport')) return Icons.sports_soccer;
    if (name.contains('news')) return Icons.newspaper;
    if (name.contains('movie')) return Icons.movie;
    if (name.contains('music')) return Icons.music_note;
    if (name.contains('kid') || name.contains('child')) return Icons.child_care;
    if (name.contains('document')) return Icons.description;
    if (name.contains('entertainment')) return Icons.celebration;
    return Icons.folder;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isSelected 
            ? AppTheme.primaryColor.withOpacity(0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        leading: Icon(
          _icon,
          size: 20,
          color: isSelected ? AppTheme.primaryColor : AppTheme.textMuted,
        ),
        title: Text(
          category.name,
          style: TextStyle(
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected ? AppTheme.primaryColor : AppTheme.textPrimary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: category.channelCount != null
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected 
                      ? AppTheme.primaryColor.withOpacity(0.2)
                      : AppTheme.textMuted.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${category.channelCount}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isSelected ? AppTheme.primaryColor : AppTheme.textMuted,
                  ),
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}

