echo "Compiling..."
git submodule update --init --recursive
rome download
fastlane scan
