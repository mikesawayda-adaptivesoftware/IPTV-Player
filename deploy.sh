#!/bin/bash

# IPTV Player - Deploy Script
# This script commits changes to GitHub and optionally builds the app

set -e  # Exit on error

REPO_URL="https://github.com/mikesawayda-adaptivesoftware/IPTV-Player.git"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   📺 IPTV Player - Deploy Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR"

echo -e "${YELLOW}📁 App directory: $APP_DIR${NC}"
echo ""

# Check for uncommitted changes
cd "$APP_DIR"
if [[ -z $(git status -s) ]]; then
    echo -e "${YELLOW}⚠️  No changes to commit${NC}"
else
    # Get commit message from user or use default
    if [ -z "$1" ]; then
        # Generate a default commit message with timestamp
        COMMIT_MSG="Update IPTV-Player - $(date '+%Y-%m-%d %H:%M')"
        echo -e "${YELLOW}💬 Using default commit message: ${COMMIT_MSG}${NC}"
    else
        COMMIT_MSG="$1"
        echo -e "${YELLOW}💬 Commit message: ${COMMIT_MSG}${NC}"
    fi
    echo ""

    # Stage all changes
    echo -e "${BLUE}📦 Staging changes...${NC}"
    git add -A

    # Commit
    echo -e "${BLUE}✍️  Committing...${NC}"
    git commit -m "$COMMIT_MSG"

    # Push to GitHub
    echo -e "${BLUE}🚀 Pushing to GitHub...${NC}"
    git remote set-url origin ${REPO_URL} 2>/dev/null || git remote add origin ${REPO_URL}
    git push origin main
    echo -e "${GREEN}✅ GitHub updated successfully!${NC}"
fi
echo ""

# Ask if user wants to build
echo -e "${YELLOW}Would you like to build the app? (y/n)${NC}"
read -r BUILD_CHOICE

if [[ "$BUILD_CHOICE" == "y" || "$BUILD_CHOICE" == "Y" ]]; then
    cd "$APP_DIR"
    
    echo -e "${BLUE}🛠️  Which build would you like to create?${NC}"
    echo -e "  1) Android APK"
    echo -e "  2) Android App Bundle (AAB)"
    echo -e "  3) Windows"
    echo -e "  4) macOS"
    echo -e "  5) All (APK, AAB, Windows, macOS)"
    read -r BUILD_TYPE

    case $BUILD_TYPE in
        1)
            echo -e "${BLUE}📱 Building Android APK...${NC}"
            flutter build apk --release
            echo -e "${GREEN}✅ APK built: build/app/outputs/flutter-apk/app-release.apk${NC}"
            ;;
        2)
            echo -e "${BLUE}📱 Building Android App Bundle...${NC}"
            flutter build appbundle --release
            echo -e "${GREEN}✅ AAB built: build/app/outputs/bundle/release/app-release.aab${NC}"
            ;;
        3)
            echo -e "${BLUE}🪟 Building Windows...${NC}"
            flutter build windows --release
            echo -e "${GREEN}✅ Windows built: build/windows/x64/runner/Release/${NC}"
            ;;
        4)
            echo -e "${BLUE}🍎 Building macOS...${NC}"
            flutter build macos --release
            echo -e "${GREEN}✅ macOS built: build/macos/Build/Products/Release/${NC}"
            ;;
        5)
            echo -e "${BLUE}📱 Building Android APK...${NC}"
            flutter build apk --release
            echo -e "${GREEN}✅ APK built!${NC}"
            
            echo -e "${BLUE}📱 Building Android App Bundle...${NC}"
            flutter build appbundle --release
            echo -e "${GREEN}✅ AAB built!${NC}"
            
            echo -e "${BLUE}🪟 Building Windows...${NC}"
            flutter build windows --release
            echo -e "${GREEN}✅ Windows built!${NC}"
            
            echo -e "${BLUE}🍎 Building macOS...${NC}"
            flutter build macos --release
            echo -e "${GREEN}✅ macOS built!${NC}"
            ;;
        *)
            echo -e "${YELLOW}Skipping build.${NC}"
            ;;
    esac
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   ✅ Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Display useful commands
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   📋 Useful Commands${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}Run on Android device:${NC}"
echo -e "  ${GREEN}flutter run${NC}"
echo ""
echo -e "${YELLOW}Run on Windows:${NC}"
echo -e "  ${GREEN}flutter run -d windows${NC}"
echo ""
echo -e "${YELLOW}Run on macOS:${NC}"
echo -e "  ${GREEN}flutter run -d macos${NC}"
echo ""
echo -e "${YELLOW}Build release APK:${NC}"
echo -e "  ${GREEN}flutter build apk --release${NC}"
echo ""
echo -e "${YELLOW}Build Windows executable:${NC}"
echo -e "  ${GREEN}flutter build windows --release${NC}"
echo ""
echo -e "${BLUE}========================================${NC}"
