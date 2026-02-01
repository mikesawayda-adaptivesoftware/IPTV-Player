#!/bin/bash
# Run IPTV Player with software OpenGL rendering to avoid GPU driver crashes

export LIBGL_ALWAYS_SOFTWARE=1
export MESA_GL_VERSION_OVERRIDE=3.3
export GALLIUM_DRIVER=llvmpipe

echo "Running with software OpenGL rendering..."
flutter run -d linux "$@"
