#!/bin/bash

# Software License Agreement (BSD License)
#
# Inspired by MoveIt! travis https://github.com/ros-planning/moveit_core/blob/09bbc196dd4388ac8d81171620c239673b624cc4/.travis.yml
# Inspired by JSK travis https://github.com/jsk-ros-pkg/jsk_travis
# Inspired by ROS Industrial https://github.com/ros-industrial/industrial_ci
#
# Author:  Dave Coleman, Jonathan Bohren, Robert Haschke, Isaac I. Y. Saito

export CI_SOURCE_PATH=$(pwd)
export CI_PARENT_DIR=.ci_config  # This is the folder name that is used in downstream repositories in order to point to this repo.
export HIT_ENDOFSCRIPT=false
export REPOSITORY_NAME=${PWD##*/}

# Helper functions
source ${CI_SOURCE_PATH}/$CI_PARENT_DIR/util.sh

# Run all CI in a Docker container
if ! [ "$IN_DOCKER" ]; then
    # Pull first to allow us to hide console output
    #docker pull moveit/moveit_docker:moveit-$ROS_DISTRO-ci > /dev/null
    docker pull moveit/moveit_docker:moveit-$ROS_DISTRO-ci

    # Start Docker container
    docker run \
        -e ROS_REPOSITORY_PATH \
        -e ROS_DISTRO \
        -e BEFORE_SCRIPT \
        -e CI_PARENT_DIR \
        -e UPSTREAM_WORKSPACE \
        -e TRAVIS_BRANCH \
        -v $(pwd):/root/$REPOSITORY_NAME moveit/moveit_docker:moveit-$ROS_DISTRO-ci \
        /bin/bash -c "cd /root/$REPOSITORY_NAME; source .ci_config/travis.sh;"
    return_value=$?

    if [ $return_value -eq 0 ]; then
        echo "ROS $ROS_DISTRO Docker container finished successfully"
        HIT_ENDOFSCRIPT=true;
        exit 0
    fi
    echo "ROS $ROS_DISTRO Docker container finished with errors"
    exit -1 # error
fi

# If we are here, we can assume we are inside a Docker container
echo "Testing branch $TRAVIS_BRANCH of $REPOSITORY_NAME on $ROS_DISTRO"

# Set apt repo - this was already defined in OSRF image but we probably want shadow-fixed
if [ ! "$ROS_REPOSITORY_PATH" ]; then # If not specified, use ROS Shadow repository http://wiki.ros.org/ShadowRepository
    export ROS_REPOSITORY_PATH="http://packages.ros.org/ros-shadow-fixed/ubuntu";
fi
# Note: cannot use "travis_run" with this command because of the various quote symbols
sudo -E sh -c 'echo "deb $ROS_REPOSITORY_PATH `lsb_release -cs` main" > /etc/apt/sources.list.d/ros-latest.list'

# Update the sources
travis_run sudo apt-get -qq update

# Setup rosdep - note: "rosdep init" is already setup in base ROS Docker image
travis_run rosdep update

# Create workspace
travis_run mkdir -p ~/ros/ws_$REPOSITORY_NAME/src
travis_run cd ~/ros/ws_$REPOSITORY_NAME/src

# Install dependencies necessary to run build using .rosinstall files
if [ ! "$UPSTREAM_WORKSPACE" ]; then
    export UPSTREAM_WORKSPACE="debian";
fi
case "$UPSTREAM_WORKSPACE" in
    debian)
        echo "Obtain deb binary for upstream packages."
        ;;
    http://* | https://*) # When UPSTREAM_WORKSPACE is an http url, use it directly
        travis_run wstool init .
        travis_run wstool merge $UPSTREAM_WORKSPACE
        ;;
    *) # Otherwise assume UPSTREAM_WORKSPACE is a local file path
        travis_run wstool init .
        if [ -e $CI_SOURCE_PATH/$UPSTREAM_WORKSPACE ]; then
            # install (maybe unreleased version) dependencies from source
            travis_run wstool merge file://$CI_SOURCE_PATH/$UPSTREAM_WORKSPACE
        fi
        ;;
esac

# download upstream packages into workspace
if [ -e .rosinstall ]; then
    # ensure that the downstream is not in .rosinstall
    travis_run wstool rm $REPOSITORY_NAME || true
    travis_run cat .rosinstall
    travis_run wstool update
fi

# link in the repo we are testing
travis_run ln -s $CI_SOURCE_PATH .

# source setup.bash
#travis_run source /opt/ros/$ROS_DISTRO/setup.bash

# Run before script
if [ "${BEFORE_SCRIPT// }" != "" ]; then sh -c "${BEFORE_SCRIPT}"; fi

# Install source-based package dependencies
travis_run sudo rosdep install -r -y -q -n --from-paths . --ignore-src --rosdistro $ROS_DISTRO

# Change to base of workspace
travis_run cd ~/ros/ws_$REPOSITORY_NAME/

# re-source setup.bash for setting environmet vairable for package installed via rosdep
#travis_run source /opt/ros/$ROS_DISTRO/setup.bash

# Configure catkin to use install configuration
#travis_run catkin config --install
travis_run catkin config --extend /opt/ros/$ROS_DISTRO --install --cmake-args -DCMAKE_BUILD_TYPE=Release

# Console output fix for: "WARNING: Could not encode unicode characters"
PYTHONIOENCODING=UTF-8

# For a command that doesn’t produce output for more than 10 minutes, prefix it with my_travis_wait
echo "Running catkin build..."
my_travis_wait 60 catkin build --no-status --summarize

# Source the new built workspace
travis_run source install/setup.bash;

# Only run tests on the current repo's packages
TEST_PKGS=$(catkin_topological_order $CI_SOURCE_PATH --only-names)
if [ -n "$TEST_PKGS" ]; then TEST_PKGS="--no-deps $TEST_PKGS"; fi
if [ "$ALLOW_TEST_FAILURE" != "true" ]; then ALLOW_TEST_FAILURE=false; fi
echo "Running tests for packages: '$TEST_PKGS'"

# Re-build workspace with tests
travis_run catkin build --no-status --summarize --make-args tests -- $TEST_PKGS

# Run tests
travis_run catkin run_tests --no-status --summarize $TEST_PKGS
catkin_test_results || $ALLOW_TEST_FAILURE

echo "Travis script has finished successfully"
HIT_ENDOFSCRIPT=true
exit 0