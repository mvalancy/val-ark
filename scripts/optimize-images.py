#!/usr/bin/env python3
"""
Image Optimization Script for Val Ark Web UI
Optimizes screenshots and logos for web delivery:
- Resizes large images to max 1200px width
- Compresses PNGs and JPEGs
- Reports savings
"""

import os
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Error: Pillow not installed. Run: pip install Pillow")
    sys.exit(1)

# Configuration
MAX_WIDTH = 1200  # Max width for screenshots
MAX_LOGO_WIDTH = 200  # Max width for logos
JPEG_QUALITY = 85
PNG_OPTIMIZE = True

def get_size_str(size_bytes):
    """Convert bytes to human-readable string."""
    if size_bytes < 1024:
        return f"{size_bytes}B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f}KB"
    else:
        return f"{size_bytes / (1024 * 1024):.2f}MB"

def optimize_image(filepath, max_width, is_logo=False):
    """Optimize a single image. Returns (original_size, new_size) or None if skipped."""
    original_size = os.path.getsize(filepath)

    try:
        img = Image.open(filepath)
        original_format = img.format
        width, height = img.size

        # Check if resize needed
        needs_resize = width > max_width

        if needs_resize:
            # Calculate new dimensions maintaining aspect ratio
            ratio = max_width / width
            new_height = int(height * ratio)
            # Use LANCZOS for high-quality downscaling (compatible with older Pillow)
            try:
                resample = Image.Resampling.LANCZOS
            except AttributeError:
                resample = Image.LANCZOS  # Pillow < 9.0
            img = img.resize((max_width, new_height), resample)

        # Determine output format and save
        ext = filepath.suffix.lower()

        if ext in ['.jpg', '.jpeg']:
            # Convert RGBA to RGB for JPEG
            if img.mode in ('RGBA', 'P'):
                img = img.convert('RGB')
            img.save(filepath, 'JPEG', quality=JPEG_QUALITY, optimize=True)
        elif ext == '.png':
            # Optimize PNG
            img.save(filepath, 'PNG', optimize=PNG_OPTIMIZE)
        else:
            return None

        new_size = os.path.getsize(filepath)
        return (original_size, new_size, needs_resize)

    except Exception as e:
        print(f"  Error processing {filepath}: {e}")
        return None

def main():
    script_dir = Path(__file__).parent
    web_ui_dir = script_dir.parent / 'web-ui'

    screenshots_dir = web_ui_dir / 'screenshots'
    logos_dir = web_ui_dir / 'logos'

    total_original = 0
    total_new = 0
    files_processed = 0
    files_resized = 0

    print("=" * 60)
    print("Val Ark Image Optimization")
    print("=" * 60)

    # Process screenshots
    if screenshots_dir.exists():
        print(f"\nProcessing screenshots in {screenshots_dir}...")
        for filepath in sorted(screenshots_dir.glob('*')):
            if filepath.suffix.lower() in ['.png', '.jpg', '.jpeg']:
                result = optimize_image(filepath, MAX_WIDTH)
                if result:
                    orig, new, resized = result
                    total_original += orig
                    total_new += new
                    files_processed += 1
                    if resized:
                        files_resized += 1

                    savings = orig - new
                    pct = (savings / orig * 100) if orig > 0 else 0
                    status = "resized + compressed" if resized else "compressed"

                    if savings > 1024:  # Only report if saved more than 1KB
                        print(f"  {filepath.name}: {get_size_str(orig)} -> {get_size_str(new)} ({status}, -{pct:.0f}%)")

    # Process logos
    if logos_dir.exists():
        print(f"\nProcessing logos in {logos_dir}...")
        for filepath in sorted(logos_dir.glob('*')):
            if filepath.suffix.lower() in ['.png', '.jpg', '.jpeg']:
                result = optimize_image(filepath, MAX_LOGO_WIDTH, is_logo=True)
                if result:
                    orig, new, resized = result
                    total_original += orig
                    total_new += new
                    files_processed += 1
                    if resized:
                        files_resized += 1

                    savings = orig - new
                    if savings > 1024:
                        pct = (savings / orig * 100) if orig > 0 else 0
                        print(f"  {filepath.name}: {get_size_str(orig)} -> {get_size_str(new)} (-{pct:.0f}%)")

    # Summary
    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    print(f"Files processed: {files_processed}")
    print(f"Files resized: {files_resized}")
    print(f"Original total: {get_size_str(total_original)}")
    print(f"Optimized total: {get_size_str(total_new)}")

    savings = total_original - total_new
    if total_original > 0:
        pct = savings / total_original * 100
        print(f"Total savings: {get_size_str(savings)} ({pct:.1f}%)")

if __name__ == '__main__':
    main()
