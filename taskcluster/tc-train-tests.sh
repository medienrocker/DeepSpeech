#!/bin/bash

set -xe

source $(dirname "$0")/tc-tests-utils.sh

extract_python_versions "$1" "pyver" "pyver_pkg" "py_unicode_type" "pyconf" "pyalias"

bitrate=$2

decoder_src=$3

if [ "$decoder_src" = "--pypi" ]; then
    # Disable automatically picking up decoder package built in this CI group
    export DECODER_ARTIFACTS_ROOT=""
fi

mkdir -p ${TASKCLUSTER_ARTIFACTS} || true
mkdir -p /tmp/train || true
mkdir -p /tmp/train_tflite || true

virtualenv_activate "${pyalias}" "deepspeech"

set -o pipefail
pip install --upgrade pip==19.3.1 setuptools==45.0.0 wheel==0.33.6 | cat
pushd ${HOME}/DeepSpeech/ds
    pip install --upgrade . | cat
popd
set +o pipefail

# Prepare correct arguments for training
case "${bitrate}" in
    8k)
        sample_rate=8000
        sample_name='LDC93S1_pcms16le_1_8000.wav'
    ;;
    16k)
        sample_rate=16000
        sample_name='LDC93S1_pcms16le_1_16000.wav'
    ;;
esac

# Easier to rename to that we can exercize the LDC93S1 importer code to
# generate the CSV file.
echo "Moving ${sample_name} to LDC93S1.wav"
mv "${DS_ROOT_TASK}/DeepSpeech/ds/data/smoke_test/${sample_name}" "${DS_ROOT_TASK}/DeepSpeech/ds/data/smoke_test/LDC93S1.wav"

pushd ${HOME}/DeepSpeech/ds/
    # Run twice to test preprocessed features
    time ./bin/run-tc-ldc93s1_new.sh 249 "${sample_rate}"
    time ./bin/run-tc-ldc93s1_new.sh 1 "${sample_rate}"
    time ./bin/run-tc-ldc93s1_tflite.sh "${sample_rate}"
popd

tar -cf - \
    -C /tmp/ckpt/ . \
    | ${XZ} > ${TASKCLUSTER_ARTIFACTS}/checkpoint.tar.xz

cp /tmp/train/output_graph.pb ${TASKCLUSTER_ARTIFACTS}
cp /tmp/train_tflite/output_graph.tflite ${TASKCLUSTER_ARTIFACTS}

pushd ${HOME}/DeepSpeech/ds/
    python util/taskcluster.py --source tensorflow --artifact convert_graphdef_memmapped_format --branch r1.15 --target /tmp/
popd

/tmp/convert_graphdef_memmapped_format --in_graph=/tmp/train/output_graph.pb --out_graph=/tmp/train/output_graph.pbmm
cp /tmp/train/output_graph.pbmm ${TASKCLUSTER_ARTIFACTS}

pushd ${HOME}/DeepSpeech/ds/
    time ./bin/run-tc-ldc93s1_checkpoint.sh
popd

virtualenv_deactivate "${pyalias}" "deepspeech"
