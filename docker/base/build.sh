#!/bin/bash
#
# Contains the main cross compiler, that individually sets up each target build
# platform, compiles all the C dependencies, then build the requested executable
# itself.
#
# Usage: build.sh <import path>
#
# Needed environment variables:
#   REPO_REMOTE - Optional VCS remote if not the primary repository is needed
#   REPO_BRANCH - Optional VCS branch to use, if not the master branch
#   DEPS        - Optional list of C dependency packages to build
#   PACK        - Optional sub-package, if not the import path is being built
#   OUT         - Optional output prefix to override the package name
#   FLAG_V      - Optional verbosity flag to set on the Go builder
#   FLAG_X      - Optional flag to print the build progress commands
#   FLAG_RACE   - Optional race flag to set on the Go builder
#   TARGETS     - Comma separated list of build targets to compile for
#   GO_VERSION  - Bootstrapped version of Go to disable uncupported targets
#   EXT_GOPATH  - GOPATH elements mounted from the host filesystem

if [ "$EXT_GOPATH" != "" ]; then
  # If local builds are requested, inject the sources
  echo "Building locally $1..."
  export GOPATH=$GOPATH:$EXT_GOPATH
  set -e

  # Find and change into the package folder
  cd `go list -e -f {{.Dir}} $1`
  export GOPATH=$GOPATH:`pwd`/Godeps/_workspace
else
  # Inject all possible Godep paths to short circuit go gets
  GOPATH_ROOT=$GOPATH/src
  IMPORT_PATH=$1
  while [ "$IMPORT_PATH" != "." ]; do
    export GOPATH=$GOPATH:$GOPATH_ROOT/$IMPORT_PATH/Godeps/_workspace
    IMPORT_PATH=`dirname $IMPORT_PATH`
  done

  # Otherwise download the canonical import path (may fail, don't allow failures beyond)
  echo "Fetching main repository $1..."
  go get -v -d $1
  set -e

  cd $GOPATH_ROOT/$1

  # Switch over the code-base to another checkout if requested
  if [ "$REPO_REMOTE" != "" ] || [ "$REPO_BRANCH" != "" ]; then
    # Detect the version control system type
    IMPORT_PATH=$1
    while [ "$IMPORT_PATH" != "." ] && [ "$REPO_TYPE" == "" ]; do
      if [ -d "$GOPATH_ROOT/$IMPORT_PATH/.git" ]; then
        REPO_TYPE="git"
      elif  [ -d "$GOPATH_ROOT/$IMPORT_PATH/.hg" ]; then
        REPO_TYPE="hg"
      fi
      IMPORT_PATH=`dirname $IMPORT_PATH`
    done

    if [ "$REPO_TYPE" == "" ]; then
      echo "Unknown version control system type, cannot switch remotes and branches."
      exit -1
    fi
    # If we have a valid VCS, execute the switch operations
    if [ "$REPO_REMOTE" != "" ]; then
      echo "Switching over to remote $REPO_REMOTE..."
      if [ "$REPO_TYPE" == "git" ]; then
        git remote set-url origin $REPO_REMOTE
        git pull
      elif [ "$REPO_TYPE" == "hg" ]; then
        echo -e "[paths]\ndefault = $REPO_REMOTE\n" >> .hg/hgrc
        hg pull
      fi
    fi
    if [ "$REPO_BRANCH" != "" ]; then
      echo "Switching over to branch $REPO_BRANCH..."
      if [ "$REPO_TYPE" == "git" ]; then
        git checkout $REPO_BRANCH
      elif [ "$REPO_TYPE" == "hg" ]; then
        hg checkout $REPO_BRANCH
      fi
    fi
  fi
fi

# Download all the C dependencies
mkdir /deps
DEPS=($DEPS) && for dep in "${DEPS[@]}"; do
  if [ "${dep##*.}" == "tar" ]; then cat "/deps-cache/`basename $dep`" | tar -C /deps -x; fi
  if [ "${dep##*.}" == "gz" ];  then cat "/deps-cache/`basename $dep`" | tar -C /deps -xz; fi
  if [ "${dep##*.}" == "bz2" ]; then cat "/deps-cache/`basename $dep`" | tar -C /deps -xj; fi
done

# Configure some global build parameters
NAME=`basename $1/$PACK`
if [ "$OUT" != "" ]; then
  NAME=$OUT
fi

if [ "$FLAG_V" == "true" ]; then V=-v; fi
if [ "$FLAG_X" == "true" ]; then X=-x; fi
if [ "$FLAG_RACE" == "true" ]; then R=-race; fi

# If no build targets were specified, inject a catch all wildcard
if [ "$TARGETS" == "" ]; then
  TARGETS="./."
fi

# Build for each requested platform individually
for TARGET in $TARGETS; do
  # Split the target into platform and architecture
  XGOOS=`echo $TARGET | cut -d '/' -f 1`
  XGOARCH=`echo $TARGET | cut -d '/' -f 2`

  # Check and build for Android targets
  if ([ $XGOOS == "." ] || [[ $XGOOS == android* ]]); then
    # Split the platform version and configure the linker options
    PLATFORM=`echo $XGOOS | cut -d '-' -f 2`
    if [ $XGOOS == "." ] || [ "$PLATFORM" == "" ] || [ "$PLATFORM" == "." ]; then
      PLATFORM=$ANDROID_PLATFORM
    fi
    if [ "$PLATFORM" -ge 16 ]; then
      CGO_CCPIE="-fPIE"
      CGO_LDPIE="-fPIE"
      EXT_LDPIE="-extldflags=-pie -extldflags=-Wl,--allow-multiple-definition"
    else
      unset CGO_CCPIE CGO_LDPIE EXT_LDPIE
    fi
    # Iterate over the requested architectures, bootstrap and
    if [ $XGOARCH == "." ] || [ $XGOARCH == "arm" ]; then
      if [ "$GO_VERSION" -lt 150 ]; then
        echo "Go version too low, skipping android-$PLATFORM/arm..."
      else
        echo "Assembling toolchain for android-$PLATFORM/arm..."
        $ANDROID_NDK_ROOT/build/tools/make-standalone-toolchain.sh --ndk-dir=$ANDROID_NDK_ROOT --install-dir=/usr/$ANDROID_CHAIN_ARM --toolchain=$ANDROID_CHAIN_ARM --arch=arm --system=linux-x86_64 > /dev/null 2>&1

        echo "Bootstrapping android-$PLATFORM/arm..."
        CC=arm-linux-androideabi-gcc GOOS=android GOARCH=arm GOARM=7 CGO_ENABLED=1 CGO_CFLAGS="$CGO_CCPIE" CGO_LDFLAGS="$CGO_LDPIE" go install std

        echo "Compiling for android-$PLATFORM/arm..."
        CC=arm-linux-androideabi-gcc CXX=arm-linux-androideabi-g++ HOST=arm-linux-androideabi PREFIX=/usr/$ANDROID_CHAIN_ARM/arm-linux-androideabi $BUILD_DEPS /deps
        CC=arm-linux-androideabi-gcc CXX=arm-linux-androideabi-g++ GOOS=android GOARCH=arm GOARM=7 CGO_ENABLED=1 CGO_CFLAGS="$CGO_CCPIE" CGO_CXXFLAGS="$CGO_CCPIE" CGO_LDFLAGS="$CGO_LDPIE" go get $V $X -d ./$PACK
        CC=arm-linux-androideabi-gcc CXX=arm-linux-androideabi-g++ GOOS=android GOARCH=arm GOARM=7 CGO_ENABLED=1 CGO_CFLAGS="$CGO_CCPIE" CGO_CXXFLAGS="$CGO_CCPIE" CGO_LDFLAGS="$CGO_LDPIE" go build --ldflags="$EXT_LDPIE" $V $X $R -o /build/$NAME-android-$PLATFORM-arm$R ./$PACK
      fi
    fi
  fi
  # Check and build for Linux targets
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "amd64" ]); then
    echo "Compiling for linux/amd64..."
    HOST=x86_64-linux PREFIX=/usr/local $BUILD_DEPS /deps
    GOOS=linux GOARCH=amd64 CGO_ENABLED=1 go get $V $X -d ./$PACK
    GOOS=linux GOARCH=amd64 CGO_ENABLED=1 go build $V $X $R -o /build/$NAME-linux-amd64$R ./$PACK
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "386" ]); then
    echo "Compiling for linux/386..."
    HOST=i686-linux PREFIX=/usr/local $BUILD_DEPS /deps
    GOOS=linux GOARCH=386 CGO_ENABLED=1 go get $V $X -d ./$PACK
    GOOS=linux GOARCH=386 CGO_ENABLED=1 go build $V $X -o /build/$NAME-linux-386 ./$PACK
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "arm" ]); then
    echo "Compiling for linux/arm..."
    CC=arm-linux-gnueabi-gcc CXX=arm-linux-gnueabi-g++ HOST=arm-linux PREFIX=/usr/local/arm $BUILD_DEPS /deps
    CC=arm-linux-gnueabi-gcc CXX=arm-linux-gnueabi-g++ GOOS=linux GOARCH=arm CGO_ENABLED=1 GOARM=5 go get $V $X -d ./$PACK
    CC=arm-linux-gnueabi-gcc CXX=arm-linux-gnueabi-g++ GOOS=linux GOARCH=arm CGO_ENABLED=1 GOARM=5 go build $V $X -o /build/$NAME-linux-arm ./$PACK
  fi
  # Check and build for Windows targets
  if ([ $XGOOS == "." ] || [ $XGOOS == "windows" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "amd64" ]); then
    echo "Compiling for windows/amd64..."
    CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ HOST=x86_64-w64-mingw32 PREFIX=/usr/x86_64-w64-mingw32 $BUILD_DEPS /deps
    CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ GOOS=windows GOARCH=amd64 CGO_ENABLED=1 go get $V $X -d ./$PACK
    CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ GOOS=windows GOARCH=amd64 CGO_ENABLED=1 go build $V $X $R -o /build/$NAME-windows-amd64$R.exe ./$PACK
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "windows" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "386" ]); then
    echo "Compiling for windows/386..."
    CC=i686-w64-mingw32-gcc CXX=i686-w64-mingw32-g++ HOST=i686-w64-mingw32 PREFIX=/usr/i686-w64-mingw32 $BUILD_DEPS /deps
    CC=i686-w64-mingw32-gcc CXX=i686-w64-mingw32-g++ GOOS=windows GOARCH=386 CGO_ENABLED=1 go get $V $X -d ./$PACK
    CC=i686-w64-mingw32-gcc CXX=i686-w64-mingw32-g++ GOOS=windows GOARCH=386 CGO_ENABLED=1 go build $V $X -o /build/$NAME-windows-386.exe ./$PACK
  fi
  # Check and build for OSX targets
  if ([ $XGOOS == "." ] || [ $XGOOS == "darwin" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "amd64" ]); then
    echo "Compiling for darwin/amd64..."
    CC=o64-clang CXX=o64-clang++ HOST=x86_64-apple-darwin10 PREFIX=/usr/local $BUILD_DEPS /deps
    CC=o64-clang CXX=o64-clang++ GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 go get $V $X -d ./$PACK
    CC=o64-clang CXX=o64-clang++ GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 go build -ldflags=-s $V $X $R -o /build/$NAME-darwin-amd64$R ./$PACK
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "darwin" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "386" ]); then
    echo "Compiling for darwin/386..."
    CC=o32-clang CXX=o32-clang++ HOST=i386-apple-darwin10 PREFIX=/usr/local $BUILD_DEPS /deps
    CC=o32-clang CXX=o32-clang++ GOOS=darwin GOARCH=386 CGO_ENABLED=1 go get $V $X -d ./$PACK
    CC=o32-clang CXX=o32-clang++ GOOS=darwin GOARCH=386 CGO_ENABLED=1 go build -ldflags=-s $V $X -o /build/$NAME-darwin-386 ./$PACK
  fi
done