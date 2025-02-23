#!/bin/bash
set -e

source ./.ci/util.sh

addCheckstyleBundleToAntResolvers() {
  xmlstarlet ed --inplace \
    -s '/ivysettings/resolvers' -t elem -n filesystem \
    -i '/ivysettings/resolvers/filesystem[last()]' -t attr -n name -v local-checkstyle \
    -s '/ivysettings/resolvers/filesystem[last()]' -t elem -n artifact \
    -i '/ivysettings/resolvers/filesystem[last()]/artifact' -t attr -n pattern -v \
    '${base.dir}/../../target/[artifact]-[revision]-all.[ext]' \
    -s '/ivysettings/modules' -t elem -n module \
    -i '/ivysettings/modules/module[last()]' -t attr -n organisation -v com.puppycrawl.tools \
    -i '/ivysettings/modules/module[last()]' -t attr -n name -v checkstyle \
    -i '/ivysettings/modules/module[last()]' -t attr -n resolver -v local-checkstyle \
    ivysettings.xml
}

case $1 in

all-sevntu-checks)
  working_dir=.ci-temp/all-sevntu-checks
  mkdir -p $working_dir
  xmlstarlet sel --net --template -m .//module -v "@name" -n config/checkstyle_sevntu_checks.xml \
    | grep -vE "Checker|TreeWalker|Filter|Holder" | grep -v "^$" \
    | sed "s/com\.github\.sevntu\.checkstyle\.checks\..*\.//" \
    | sort | uniq | sed "s/Check$//" > $working_dir/file.txt
  wget -q http://sevntu-checkstyle.github.io/sevntu.checkstyle/apidocs/allclasses-frame.html -O - \
    | grep "<li>" | cut -d '>' -f 3 | sed "s/<\/a//" \
    | grep -E "Check$" \
    | sort | uniq | sed "s/Check$//" > $working_dir/web.txt
  # temporal ignore list
  # sed -i.backup '/Jsr305Annotations/d' web.txt
  diff -u $working_dir/web.txt $working_dir/file.txt
  removeFolderWithProtectedFiles $working_dir
  ;;

check-missing-pitests)
  fail=0
  mkdir -p target

  list=($(cat pom.xml | \
    xmlstarlet sel --ps -N pom="http://maven.apache.org/POM/4.0.0" \
    -t -v '//pom:profile[./pom:id[contains(text(),'pitest')]]//pom:targetClasses/pom:param'))

  #  Temporary skip for Metadata generator related files for
  #  https://github.com/checkstyle/checkstyle/issues/8761
  list=("com.puppycrawl.tools.checkstyle.meta.*" "${list[@]}")

  CMD="find src/main/java -type f ! -name 'package-info.java'"

  for item in "${list[@]}"
  do
    item=${item//\./\/}
    if [[ $item == */\*  ]] ; then
     item=$item
    else
      if [[ $item != *\* ]] ; then
        item="$item.java"
      else
        item="${item::-1}.java"
      fi
    fi

    CMD="$CMD -and ! -wholename '*/$item'"
  done

  CMD="$CMD | sort > target/result.txt"
  eval $CMD

  results=$(cat target/result.txt)

  echo "List of missing files in pitest profiles: $results"

  if [[ -n $results ]] ; then
    fail=1
  fi

  sleep 5s
  exit $fail
  ;;

eclipse-static-analysis)
  mvn -e --no-transfer-progress clean compile exec:exec -Peclipse-compiler
  ;;

eclipse-static-analysis-java11)
  # Ensure that project sources can be compiled by eclipse with Java11 language features.
  mvn -e --no-transfer-progress clean compile exec:exec -Peclipse-compiler -D java.version=11
  ;;

java11-verify)
  # Ensure that project sources can be compiled by jdk with Java11 language features.
  mvn -e --no-transfer-progress clean verify -D java.version=11
  ;;

nondex)
  # Below we exclude test that fails due to picocli library usage
  mvn -e --no-transfer-progress --fail-never clean nondex:nondex -DargLine='-Xms1024m -Xmx2048m' \
    -Dtest=!JavadocPropertiesGeneratorTest#testNonExistentArgument
  mkdir -p .ci-temp
  cat `grep -RlE 'td class=.x' .nondex/ | cat` < /dev/null > .ci-temp/output.txt
  RESULT=$(cat .ci-temp/output.txt | wc -c)
  cat .ci-temp/output.txt
  echo 'Size of output:'$RESULT
  if [[ $RESULT != 0 ]]; then sleep 5s; false; fi
  rm .ci-temp/output.txt
  ;;

no-error-pmd)
  CS_POM_VERSION="$(getCheckstylePomVersion)"
  echo "CS_version: ${CS_POM_VERSION}"
  checkout_from "-b checkstyle-7417 https://github.com/nmancus1/build-tools.git"
  cd .ci-temp/build-tools/
  PMD_POM_VERSION=$(mvn -e --no-transfer-progress -q -Dexec.executable='echo' \
    -Dexec.args='${project.version}' \
     --non-recursive org.codehaus.mojo:exec-maven-plugin:1.3.1:exec)
  mvn -e --no-transfer-progress install
  cd ..
  git clone https://github.com/pmd/pmd.git
  cd pmd
  # Using specific commit so that build-tools dependencies match
  git checkout 342dc1d03aaa1082e42f7496d6869d15859af321
  mvn -e --no-transfer-progress install checkstyle:check -Dcheckstyle.version=${CS_POM_VERSION} \
    -Dpmd.build-tools.version=${PMD_POM_VERSION}
  cd ..
  removeFolderWithProtectedFiles build-tools
  removeFolderWithProtectedFiles pmd
  ;;

no-violation-test-configurate)
  CS_POM_VERSION="$(getCheckstylePomVersion)"
  echo "CS_version: ${CS_POM_VERSION}"
  mkdir -p .ci-temp
  cd .ci-temp
  git clone https://github.com/SpongePowered/Configurate.git
  cd Configurate
  ./gradlew -PcheckstyleVersion="${CS_POM_VERSION}" -x test check
  cd ..
  removeFolderWithProtectedFiles Configurate
  ;;

no-violation-test-josm)
  CS_POM_VERSION="$(getCheckstylePomVersion)"
  echo "CS_version: ${CS_POM_VERSION}"
  mkdir -p .ci-temp
  cd .ci-temp
  TESTED=$(wget -q -O - https://josm.openstreetmap.de/wiki/TestedVersion?format=txt)
  echo "JOSM revision: ${TESTED}"
  svn -q --force export https://josm.openstreetmap.de/svn/trunk/ -r "${TESTED}" --native-eol LF josm
  cd josm
  sed -i -E "s/(name=\"checkstyle\" rev=\")([0-9]+\.[0-9]+(-SNAPSHOT)?)/\1${CS_POM_VERSION}/" \
   tools/ivy.xml
  addCheckstyleBundleToAntResolvers
  ant -v checkstyle
  grep "<error" checkstyle-josm.xml | cat > errors.log
  echo "Checkstyle Errors:"
  RESULT=$(wc -l < errors.log)
  cat errors.log
  echo "Size of output: ${RESULT}"
  cd ..
  removeFolderWithProtectedFiles josm
  if [[ ${RESULT} != 0 ]]; then false; fi
  ;;

*)
  echo "Unexpected argument: $1"
  sleep 5s
  false
  ;;

esac
