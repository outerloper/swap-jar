#!/bin/bash

debug=':'

display-help() {
    local name=$(basename "${BASH_SOURCE}")
    echo "With this script you are able to substitute specified .class files in a jar with corresponding files from another jar - within one run.
You can also restore this modified jar to its initial state.
Changes done with the subsequent script calls are NOT incremental - every run modifies the original jar.

Usages:
  ./${name} path/to.jar targetUrl [options] < STDIN
    [1] On STDIN you provide .java files paths relative to package root directory e.g. java/lang/String.java - each one in a separate line.
    [2] path/to.jar is the path to jar from which .class files corresponding to .java files from [1] will be taken.
    [3] targetUrl is the location of a jar with the same name as in [2], whose .class files will be overwritten with the ones from [2].
        Formats allowed:
        - local/directory/containing/target/jar
        - user@host:/remote/directory/containing/target/jar  - in this case you will be asked for the user's password twice.
  ./${name} --help
    Displays this help message and exits.

Options:
  --restore  If the jar was already modified, with this option it will be restored to the original state.
  --verbose  Prints debug information.

Example:
  echo 'org/foo/Bar.java' | ./${name} path/to/jar/my.jar user@my.host.com:/target/path
    This takes class org.foo.Bar and all its inner classes from path/to/jar/my.jar and puts them into /target/path/my.jar on my.host.com.

Useful information:
  svn status . | grep '^[AM]' | awk '{print $2}'
    Execute this line at the directory containing versioned package root - to list uncommited files as an input for ${name}.
  find . -mtime -2
    Execute this line at the directory containing versioned package root - to list files modified in last 2 days as an input for ${name}.
"
}

resolve-target() {
    targetUrl=$1
    targetDir=${targetUrl#*:}
    targetUrl=${targetUrl%${targetDir}}
    targetUrl=${targetUrl%:}
    host=${targetUrl#*@}
    targetUrl=${targetUrl%${host}}
    targetUrl=${targetUrl%@}
    user=${targetUrl}

    if [[ -z "${targetDir}" ]]
    then
        echo "[ERROR] missing target path"
        display-help
        exit 1
    elif [[ -n "${user}" ]] && [[ -z "${host}" ]]
    then
        echo "[ERROR] missing host name"
        display-help
        exit 1
    elif [[ -n "${host}" ]]
    then
        sendCommand="scp ${swapJarName} ${user}@${host}:${targetDir}/"
        targetRunner="ssh ${user:+${user}@}${host}"
    else
        sendCommand="cp ${swapJarName} ${targetDir}/"
        targetRunner="eval"
    fi
}

handle-options() {
    while [[ $# -gt 0 ]]
    do
        case $1 in
        --restore)
            restoreCommand="
            if [[ -f '${targetOrigJarPath}' ]]
            then
                mv '${targetOrigJarPath}' '${targetDir}/${jarName}' &&
                rm -rf ${targetWorkingDir}/${jarNameWithoutExt}* ||
                false
            else
                echo 'Nothing to restore.'
            fi
            "
            ;;
        --verbose)
            debug=echo
        esac
        shift
    done
}

if [[ $1 == --help ]]
then
    display-help
    exit 127
fi

jarPath=$(readlink -f "$1")
jarName=$(basename "${jarPath}")
jarNameWithoutExt="${jarName%.jar}"
jarDir=$(dirname "${jarPath}")
workingDir="${jarDir}/.jar-prepare"
unzippedJarPath="${workingDir}/${jarNameWithoutExt}.orig"
classesForSwapDir="${workingDir}/${jarNameWithoutExt}.swap"
classesForSwapName="${jarNameWithoutExt}.swap"
swapJarName="${jarNameWithoutExt}.swap.zip"
targetWorkingDirName=".jar-swap"

shift
resolve-target "$1"

targetWorkingDir="${targetDir}/${targetWorkingDirName}"
targetOrigJarName="${jarNameWithoutExt}.orig.jar"
targetOrigJarPath="${targetWorkingDir}/${targetOrigJarName}"
targetJarPath="${targetDir}/${jarName}"
targetSwappedDir="${jarNameWithoutExt}.swapped"
targetCommand="mkdir -p '${targetWorkingDir}' &&
    cd '${targetWorkingDir}' &&

    mv '../${swapJarName}' '${swapJarName}' &&
    {
        [[ -f '${targetOrigJarName}' ]] || cp '../${jarName}' '${targetOrigJarName}'
    } &&

    rm -rf '${classesForSwapName}' &&
    unzip '${swapJarName}' -d '${classesForSwapName}' >/dev/null &&

    rm -rf '${targetSwappedDir}' &&
    unzip '${targetOrigJarName}' -d '${targetSwappedDir}' >/dev/null &&

    cp -r ${classesForSwapName}/* ${targetSwappedDir}/ &&
    chmod -R u+rw ${targetSwappedDir}/ &&

    cd ${targetSwappedDir} &&
    zip -r '../../${jarName}' . >/dev/null ||
    false
"

shift
handle-options $@

${debug} "
sendCommand          = ${sendCommand}
targetRunner         = ${targetRunner}
jarPath              = ${jarPath}
jarName              = ${jarName}
jarNameWithoutExt    = ${jarNameWithoutExt}
jarParent            = ${jarDir}
swapDir              = ${workingDir}
unzippedJarPath      = ${unzippedJarPath}
swapJarPath          = ${classesForSwapDir}
swapJarToZipName     = ${classesForSwapName}
swapJarName          = ${swapJarName}
targetWorkingDirName = ${targetWorkingDirName}
targetWorkingDir     = ${targetWorkingDir}
targetOrigJarName    = ${targetOrigJarName}
targetSwappedDir     = ${targetSwappedDir}
"

if [[ "${restoreCommand}" ]]
then
    ${debug} "Attempting to restore jar at ${targetJarPath}..." &&
    ${targetRunner} "${restoreCommand}" &&
    echo '[SUCCESS]' ||
    echo '[FAILED]'
else
    rm -rf "${workingDir}" &&
    mkdir "${workingDir}" &&

    ${debug} "Unpacking ${jarName} into ${jarNameWithoutExt} at ${jarDir}..."
    cd "${jarDir}" &&
    unzip "${jarName}" -d "${jarNameWithoutExt}" >/dev/null &&
    mv "${jarNameWithoutExt}" "${unzippedJarPath}" &&
    chmod -R u+rw "${unzippedJarPath}" &&

    cd ${unzippedJarPath} &&
    echo "Packing for swap the classes corresponding to the following source files:" &&
    while read javaFile
    do
        [[ "${javaFile}" =~ .java$ ]] || continue
        echo "  ${javaFile}" 1>&2 &&
        swapClassDir="${classesForSwapDir}/$(dirname ${javaFile})" &&
        mkdir -p "${swapClassDir}" &&
        cp ${javaFile%.java}*.class "${swapClassDir}/" &&
        areClassesToSwap=1
    done &&

    {
        [[ -n "${areClassesToSwap}" ]] || echo 'No .class file to swap.'
    } &&

    cd "${workingDir}/${classesForSwapName}" &&
    zip -r "../${swapJarName}" . >/dev/null &&
    cd .. &&

    ${debug} "Sending classes for swap..." &&
    ${debug} "Executing: ${sendCommand}" &&
    ${sendCommand} &&
    ${debug} "Swapping classes at ${targetDir}..." &&
    ${targetRunner} "${targetCommand}" &&
    echo '[SUCCESS]' ||
    echo '[FAILED]'
fi
