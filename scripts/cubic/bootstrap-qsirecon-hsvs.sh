## NOTE ##
# This workflow is derived from the Datalad Handbook

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed
#conda activate
#if [ $? -gt 0 ]; then
#    echo "Error initializing conda. Exiting"
#    exit $?
#fi

# Arguments:
# 1. qsiprep bootstrap directory
# 2. fmriprep bootstrap directory
# 3. qsiprep container dataset directory
# 4. Path to the MNI template
# 5. suffix for this bootstrap directory


DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

# The fifth argument can be a suffix for the bootstrap directory
suffix=""
if [[ $# -gt 4 ]]; then
    suffix='_'${5}
fi

##  qsiprep input
QSIPREPINPUT=$1
if [[ -z ${QSIPREPINPUT} ]]
then
    echo "Required argument is an identifier of the QSIPrep output zips"
    # exit 1
fi

if [[ ! -d "${QSIPREPINPUT}/output_ria/alias/data" ]]
then
    echo "There must be alias in the output ria store that points to the"
    echo "QSIPrep output dataset"
    # exit 1
fi

##  qsirecon input
FREESURFERINPUT=$2
if [[ -z ${FREESURFERINPUT} ]]
then
    echo "Required argument is an identifier of the FreeSurfer output zips"
    # exit 1
fi

if [[ ! -d "${FREESURFERINPUT}/output_ria/alias/data" ]]
then
    echo "There must be alias in the output ria store that points to the"
    echo "QSIPrep output dataset"
    # exit 1
fi

set -e -u

## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/sifthsvs
if [[ -d ${PROJECTROOT} ]]
then
    echo ${PROJECTROOT} already exists
    # exit 1
fi

if [[ ! -w $(dirname ${PROJECTROOT}) ]]
then
    echo Unable to write to ${PROJECTROOT}\'s parent. Change permissions and retry
    # exit 1
fi

## Start making things
mkdir -p ${PROJECTROOT}
cd ${PROJECTROOT}

# Jobs are set up to not require a shared filesystem (except for the lockfile)
# ------------------------------------------------------------------------------
# RIA-URL to a different RIA store from which the dataset will be cloned from.
# Both RIA stores will be created
input_store="ria+file://${PROJECTROOT}/input_ria"
output_store="ria+file://${PROJECTROOT}/output_ria"

# Create a source dataset with all analysis components as an analysis access
# point.
datalad create -c yoda analysis
cd analysis

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"

echo "Cloning input dataset into analysis dataset"
datalad clone -d . ria+file://${QSIPREPINPUT}/output_ria#~data inputs/data/qsiprep
git commit --amend -m 'Register qsiprep results dataset as a subdataset'
datalad clone -d . ria+file://${FREESURFERINPUT}/output_ria#~data inputs/data/fmriprep
# amend the previous commit with a nicer commit message
git commit --amend -m 'Register freesurfer/fmriprep dataset as a subdataset'

SUBJECTS=$(find inputs/data/qsiprep -name '*.zip' | cut -d '/' -f 4 | cut -d '_' -f 1 | sort | uniq)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi

cd ${PROJECTROOT}

CONTAINERDS=$3
if [[ ! -z "${CONTAINERDS}" ]]; then
    datalad clone ${CONTAINERDS} pennlinc-containers
fi

cd ${PROJECTROOT}/analysis
datalad install  -d . --source ${PROJECTROOT}/pennlinc-containers

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=24G
#$ -l s_vmem=16G
#$ -l tmpfree=50G
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

# Set up the remotes and get the subject id from the call
dssource="$1"
pushgitremote="$2"
subid="$3"

# change into the cluster-assigned temp directory. Not done by default in SGE
# cd ${CBICA_TMPDIR}
# OR Run it on a shared network drive
cd /cbica/comp_space/$(basename $HOME)

# Used for the branch names and the temp dir
BRANCH="job-${JOB_ID}-${subid}"
mkdir ${BRANCH}
cd ${BRANCH}

# get the analysis dataset, which includes the inputs as well
# importantly, we do not clone from the lcoation that we want to push the
# results to, in order to avoid too many jobs blocking access to
# the same location and creating a throughput bottleneck
datalad clone "${dssource}" ds

# all following actions are performed in the context of the superdataset
cd ds

# in order to avoid accumulation temporary git-annex availability information
# and to avoid a syncronization bottleneck by having to consolidate the
# git-annex branch across jobs, we will only push the main tracking branch
# back to the output store (plus the actual file content). Final availability
# information can be establish via an eventual `git-annex fsck -f joc-storage`.
# this remote is never fetched, it accumulates a larger number of branches
# and we want to avoid progressive slowdown. Instead we only ever push
# a unique branch per each job (subject AND process specific name)
git remote add outputstore "$pushgitremote"

# all results of this job will be put into a dedicated branch
git checkout -b "${BRANCH}"

# we pull down the input subject manually in order to discover relevant
# files. We do this outside the recorded call, because on a potential
# re-run we want to be able to do fine-grained recomputing of individual
# outputs. The recorded calls will have specific paths that will enable
# recomputation outside the scope of the original setup

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Do the run!

datalad get -r pennlinc-containers
datalad get -n -r inputs/data
QSIPREP_ZIP=$(ls inputs/data/qsiprep/${subid}_qsiprep*.zip | cut -d '@' -f 1 || true)
FREESURFER_ZIP=$(ls inputs/data/fmriprep/${subid}_free*.zip | cut -d '@' -f 1 || true)

datalad run \
    -i code/qsirecon_zip.sh \
    -i ${QSIPREP_ZIP} \
    -i ${FREESURFER_ZIP} \
    --explicit \
    -o MNI \
    -m "transform ${subid}" \
    "bash ./code/qsirecon_zip.sh ${subid} ${QSIPREP_ZIP} ${FREESURFER_ZIP}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

# remove tempdir 
echo TMPDIR TO DELETE
echo ${BRANCH}

datalad drop -r . --nocheck
datalad uninstall -r inputs/data
git annex dead here
cd ../..
rm -rf $BRANCH

echo SUCCESS
# job handler should clean up workspace

EOT

chmod +x code/participant_job.sh


cat > code/qsirecon_zip.sh << "EOT"
#!/bin/bash
set -e -u -x

subid="$1"
qsiprep_zip="$2"
freesurfer_zip="$3"
wd=${PWD}

cd inputs/data/qsiprep
7z x `basename ${qsiprep_zip}`
cd ../fmriprep
7z x `basename ${freesurfer_zip}`
cd $wd

mkdir -p ${PWD}/.git/tmp/wkdir
singularity run \
    --cleanenv -B ${PWD} \
    pennlinc-containers/.datalad/environments/qsiprep-0-15-0a/image \
    inputs/data/qsiprep/qsiprep qsirecon participant \
    --participant_label $subid \
    --recon-input inputs/data/qsiprep/qsiprep \
    --fs-license-file code/license.txt \
    --nthreads ${NSLOTS} \
    --stop-on-first-crash \
    --recon-only \
    --freesurfer-input inputs/data/fmriprep/freesurfer \
    --recon-spec mrtrix_singleshell_ss3t_ATC-hsvs \
    -w ${PWD}/.git/tmp/wkdir

cd qsirecon
7z a ../${subid}_qsirecon-0-15-0a.zip qsirecon
rm -rf prep .git/tmp/wkdir

EOT

chmod +x code/qsirecon_zip.sh

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"

# Add a script for merging outputs
MERGE_POSTSCRIPT=https://raw.githubusercontent.com/PennLINC/TheWay/main/scripts/cubic/merge_outputs_postscript.sh
cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT
echo "outputsource=${output_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)" \
    >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh
wget -qO- ${MERGE_POSTSCRIPT} >> code/merge_outputs.sh



################################################################################
# SGE SETUP START - remove or adjust to your needs
################################################################################
env_flags="-v DSLOCKFILE=${PWD}/.SGE_datalad_lock"

echo '#!/bin/bash' > code/qsub_calls.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
for subject in ${SUBJECTS}; do
  echo "qsub -cwd ${env_flags} -N qsirecon${subject} ${eo_args} \
  ${PWD}/code/participant_job.sh \
  ${dssource} ${pushgitremote} ${subject} " >> code/qsub_calls.sh
done
datalad save -m "SGE submission setup" code/ .gitignore

################################################################################
# SGE SETUP END
################################################################################

# cleanup - we have generated the job definitions, we do not need to keep a
# massive input dataset around. Having it around wastes resources and makes many
# git operations needlessly slow
datalad uninstall -r --nocheck inputs/data


# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output



# Add an alias to the data in the RIA store
RIA_DIR=$(find $PROJECTROOT/output_ria/???/ -maxdepth 1 -type d | sort | tail -n 1)
mkdir -p ${PROJECTROOT}/output_ria/alias
ln -s ${RIA_DIR} ${PROJECTROOT}/output_ria/alias/data

# if we get here, we are happy
echo SUCCESS

#run last sge call to test
#$(tail -n 1 code/qsub_calls.sh)

