#!/usr/bin/env python3
"""
Instagram Feed Sync for Haus of Sutra Website
Downloads the latest 6 posts from @hausofsutra, tracking what's already downloaded.
Outputs Behold-compatible JSON for the website frontend.
"""

import instaloader
import os
import json
from pathlib import Path
from datetime import datetime

# Configuration
PROFILE = "hausofsutra"
POST_COUNT = 6
SCRIPT_DIR = Path(__file__).parent
POSTS_DIR = SCRIPT_DIR / "posts"
FEED_FILE = SCRIPT_DIR / "feed.json"
SHORTCODES_FILE = SCRIPT_DIR / "shortcodes.txt"
PROFILE_PIC = SCRIPT_DIR / "profile.jpg"


def load_existing_shortcodes():
    """Load list of already-downloaded shortcodes."""
    if SHORTCODES_FILE.exists():
        return set(SHORTCODES_FILE.read_text().strip().split('\n'))
    return set()


def save_shortcodes(shortcodes):
    """Save current shortcodes to tracking file."""
    SHORTCODES_FILE.write_text('\n'.join(sorted(shortcodes)))


def cleanup_old_posts(current_shortcodes):
    """Remove images for posts no longer in the top 6."""
    if not POSTS_DIR.exists():
        return
    
    for img_file in POSTS_DIR.glob("*.jpg"):
        shortcode = img_file.stem
        if shortcode not in current_shortcodes:
            print(f"  Removing old post: {shortcode}")
            img_file.unlink()


def main():
    POSTS_DIR.mkdir(exist_ok=True)
    
    # Initialize Instaloader
    L = instaloader.Instaloader(
        download_pictures=False,
        download_videos=False,
        download_video_thumbnails=False,
        download_geotags=False,
        download_comments=False,
        save_metadata=False,
        compress_json=False,
    )

    # Try to load saved session for better reliability
    SESSION_USER_FILE = SCRIPT_DIR / ".insta_session_user"
    if SESSION_USER_FILE.exists():
        session_username = SESSION_USER_FILE.read_text().strip()
        try:
            L.load_session_from_file(session_username)
            print(f"Loaded saved session for @{session_username}")
        except Exception:
            print("Note: Could not load saved session, using anonymous access")

    print(f"Fetching profile: {PROFILE}")
    profile = instaloader.Profile.from_username(L.context, PROFILE)
    
    # Download profile picture if it doesn't exist
    if not PROFILE_PIC.exists():
        print("Downloading profile picture...")
        L.context.get_and_write_raw(profile.profile_pic_url, str(PROFILE_PIC))
        print(f"  ✓ Saved profile.jpg")
    
    # Load existing shortcodes
    existing_shortcodes = load_existing_shortcodes()
    
    # Collect latest posts
    posts_data = []
    current_shortcodes = set()
    
    print(f"\nProcessing latest {POST_COUNT} posts...")
    
    for i, post in enumerate(profile.get_posts()):
        if i >= POST_COUNT:
            break
        
        shortcode = post.shortcode
        current_shortcodes.add(shortcode)
        image_path = POSTS_DIR / f"{shortcode}.jpg"
        
        # Download image if we don't have it
        if shortcode not in existing_shortcodes or not image_path.exists():
            print(f"  Downloading new post: {shortcode}")
            
            # Get first image (slideshow) or main image
            if post.typename == "GraphSidecar":
                first_node = next(post.get_sidecar_nodes())
                image_url = first_node.display_url
            else:
                image_url = post.url
            
            L.context.get_and_write_raw(image_url, str(image_path))
        else:
            print(f"  Skipping (already have): {shortcode}")
        
        # Build post data in Behold-compatible format
        caption = post.caption or ""
        posts_data.append({
            "id": shortcode,
            "permalink": f"https://www.instagram.com/p/{shortcode}/",
            "caption": caption,
            "prunedCaption": caption[:150] + "..." if len(caption) > 150 else caption,
            "mediaUrl": f"./instagram/posts/{shortcode}.jpg",
            "thumbnailUrl": f"./instagram/posts/{shortcode}.jpg",
            "sizes": {
                "large": {
                    "mediaUrl": f"./instagram/posts/{shortcode}.jpg"
                }
            },
            "mediaType": "VIDEO" if post.is_video else "IMAGE",
            "isReel": post.is_video and post.typename == "GraphVideo",
            "timestamp": post.date_utc.isoformat(),
            "likesCount": post.likes if post.likes >= 0 else 0
        })
    
    # Build feed JSON (Behold-compatible structure)
    feed_data = {
        "username": profile.username,
        "profilePictureUrl": "./instagram/profile.jpg",
        "posts": posts_data
    }
    
    # Save feed JSON
    with open(FEED_FILE, "w", encoding="utf-8") as f:
        json.dump(feed_data, f, indent=2, ensure_ascii=False)
    print(f"\n✓ Saved feed.json with {len(posts_data)} posts")
    
    # Cleanup old posts and save current shortcodes
    cleanup_old_posts(current_shortcodes)
    save_shortcodes(current_shortcodes)
    
    print("Done!")


if __name__ == "__main__":
    main()
