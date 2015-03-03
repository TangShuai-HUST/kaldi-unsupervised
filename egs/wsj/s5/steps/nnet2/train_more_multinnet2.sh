#!/bin/bash

# Copyright 2014  Vimal Manohar
# Apache 2.0.

# This script trains several neural networks at once with different 
# objective functions and different data. The neural networks are supposed 
# to have the same architecture. The sharing of parameters among different
# neural networks can be varied.
# The input "degs" directories must be dumped by one of the
# get_egs_discriminative2.sh scripts.
# The input "uegs" directory must be dumped by one of the get_uegs2.sh scripts.
# The input "egs" directory must be dumped by one of the get_egs2.sh scripts.

# Note: the temporary data is put in <exp-dir>/uegs/, <exp-dir>/degs/,
# <exp-dir>/egs/ so if you want to use a different disk for that, just make that
# a soft link to some other volume.

# Begin configuration section.
cmd=run.pl
num_epochs=4        # Number of epochs of training
learning_rate=9e-5  # Learning rate for the first neural network. You can
                    # additionally add scales on the others.
minibatch_size=128 # by default use a smallish minibatch size for neural net
# training; this controls instability which would otherwise
# be a problem with multi-threaded update. 
 
acoustic_scale=0.1  # acoustic scale
objectives="nce smbr"
boost=0.0           # option relevant for MMI
drop_frames=false   # option relevant for MMI
num_jobs_nnet="4 4"    # Number of neural net jobs to run in parallel, one per
                       # language..  Note: this will interact with the learning
                       # rates (if you decrease this, you'll have to decrease
                       # the learning rate, and vice versa).
learning_rate_scales="1.0 1.0"
modify_learning_rates=false
separate_learning_rates=false
skip_last_layer=true
last_layer_factor=1.0  # relates to modify-learning-rates
first_layer_factor=1.0 # relates to modify-learning-rates
shuffle_buffer_size=5000 # This "buffer_size" variable controls randomization of the samples
                # on each iter.  You could set it to 0 or to a large value for complete
                # randomization, but this would both consume memory and cause spikes in
                # disk I/O.  Smaller is easier on disk and memory but less random.  It's
                # not a huge deal though, as samples are anyway randomized right at the start.
stage=-14
num_threads=16  # this is the default but you may want to change it, e.g. to 1 if
                # using GPUs.
cleanup=false
retroactive=false
use_preconditioning=false
prior_subset_size=10000 # 10k samples per job, for computing priors.  Should be
                        # more than enough.
src_models=             # can be used to override the defaults of
                        # <uegs-dir-1>/final.mdl <degs-dir-2>/final.mdl .. etc.
# End configuration section.


echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# -lt 3 ]; then
  echo "Usage: $0 [opts] <uegs-dir1/degs-dir1/egs-dir1> <uegs-dir2/degs-dir2/egs-dir2> ...  <uegs-dirN/degs-dirN/egs-dirN> <exp-dir>"
  echo " e.g.: $0 exp/tri4_uegs exp/tri4_mpe_degs exp/tri4_nce_mpe_multinnet"
  echo ""
  echo "Main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config file containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --num-epochs <#epochs|4>                         # Number of epochs of training"
  echo "  --learning-rate <learning-rate|9e-5>             # Learning rate"
  echo "  --num-jobs-nnet <num-jobs|8>                     # Number of parallel jobs to use for main neural net"
  echo "                                                   # training (will affect results as well as speed; try 8, 16)"
  echo "                                                   # Note: if you increase this, you may want to also increase"
  echo "                                                   # the learning rate."
  echo "  --num-threads <num-threads|16>                   # Number of parallel threads per job (will affect results"
  echo "                                                   # as well as speed; may interact with batch size; if you increase"
  echo "                                                   # this, you may want to decrease the batch size."
  echo "                                                   # use multiple threads... note, you might have to reduce mem"
  echo "                                                   # versus your defaults, because it gets multiplied by the -pe smp argument."
  echo "  --max-jobs-run <num-jobs|5>                      # Options given to e.g. queue.pl for jobs that do a lot of I/O."
  echo "  --samples-per-iter <#samples|200000>             # Number of samples of data to process per iteration, per"
  echo "                                                   # process."
  echo "  --stage <stage|-8>                               # Used to run a partially-completed training process from somewhere in"
  echo "                                                   # the middle."
  echo "  --criterion <criterion|smbr>                     # Training criterion: may be smbr, mmi or mpfe"
  echo "  --boost <boost|0.0>                              # Boosting factor for MMI (e.g., 0.1)"
  echo "  --modify-learning-rates <true,false|false>       # If true, modify learning rates to try to equalize relative"
  echo "                                                   # changes across layers."
  echo "  --src-model <model|"">                           # Use a difference model than \$srcdir/final.mdl"
  exit 1;
fi

argv=("$@") 
num_args=$#
num_lang=$[$num_args-1]

dir=${argv[$num_args-1]}

objectives_array=($objectives)
! [ "${#objectives_array[@]}" -eq "$num_lang" ] && \
  echo "$0: --objectives option must have size equal to the number of neural nets ($num_lang)" && exit 1;

num_jobs_nnet_array=($num_jobs_nnet)
! [ "${#num_jobs_nnet_array[@]}" -eq "$num_lang" ] && \
  echo "$0: --num-jobs-nnet option must have size equal to the number of languages ($num_lang)" && exit 1;

learning_rate_scales_array=($learning_rate_scales)
! [ "${#learning_rate_scales_array[@]}" -eq "$num_lang" ] && \
  echo "$0: --learning-rate-scales option must have size equal to the number of languages ($num_lang)" && exit 1;

! perl -e "if(${learning_rate_scales_array[0]} != 1) {exit(1);}" && \
  echo "$0: learning-rate-scale for first lang must be 1.0" && exit 1

# initially create dummy variable to store egs directories
for lang in $(seq 0 $[$num_lang-1]); do
  all_egs_dir[$lang]=${argv[$lang]}
done

if [ ! -z "$src_models" ]; then
  src_model_array=($src_models)
  ! [ "${#src_model_array[@]}" -eq "$num_lang" ] && \
    echo "$0: --src-models option must have size equal to the number of languages" && exit 1;
else
  for lang in $(seq 0 $[$num_lang-1]); do
    src_model_array[$lang]=${all_egs_dir[$lang]}/final.mdl
  done
fi

mkdir -p $dir/log || exit 1;

for lang in $(seq 0 $[$num_lang-1]); do
  this_egs_dir=${all_egs_dir[$lang]}
  mdl=${src_model_array[$lang]}
  this_num_jobs_nnet=${num_jobs_nnet_array[$lang]}
  this_obj=${objectives_array[$lang]}

  if [ "$this_obj" == "ml" ]; then
    [ ! -f $this_egs_dir/egs.1.ark ] && echo "$0: $this_egs_dir does not contain egs for ml training" && exit 1
  elif [ "$this_obj" == "nce" ]; then
    [ ! -f $this_egs_dir/uegs.1.ark ] && echo "$0: $this_egs_dir does not contain uegs for nce training" && exit 1
  else
    [ "$this_obj" != "mmi" ] && [ "$this_obj" != "mpe" ] && [ "$this_obj" != "smbr" ] && \
      echo "$0: Unknown objective '$this_obj' for language $lang. Must be ml|nce|mmi|mpe|smbr." && exit 1
    [ ! -f $this_egs_dir/degs.1.ark ] && echo "$0: $this_egs_dir does not contain degs for supervised discriminative training" && exit 1
    silphonelist_array[$lang]=$(cat $this_egs_dir/info/silence.csl) || exit 1;
  fi

  # Check inputs
  for f in $this_egs_dir/info/num_archives $mdl; do
    [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
  done
  mkdir -p $dir/$lang/log || exit 1;

  # check for valid num-jobs-nnet.
  ! [ $this_num_jobs_nnet -gt 0 ] && echo "Bad num-jobs-nnet option '$num_jobs_nnet'" && exit 1;
  this_num_archives=$(cat $this_egs_dir/info/num_archives) || exit 1;
  num_archives_array[$lang]=$this_num_archives

  if [ $this_num_jobs_nnet -gt $this_num_archives ]; then
    echo "$0: num-jobs-nnet $this_num_jobs_nnet exceeds number of archives $this_num_archives"
    echo " ... for language $lang; setting it to $this_num_archives."
    num_jobs_nnet_array[$lang]=$this_num_archives
  fi

  # copy some things from the input directories.
  for f in splice_opts cmvn_opts tree final.mat; do
    if [ -f $this_egs_dir/$f ]; then
      cp $this_egs_dir/$f $dir/$lang/ || exit 1;
    fi
  done
  if [ -f $this_egs_dir/conf ]; then
    ln -sf $(readlink -f $this_egs_dir/conf) $dir/ || exit 1; 
  fi
done

# work out number of iterations.
num_archives0=$(cat ${all_egs_dir[0]}/info/num_archives) || exit 1;
num_jobs_nnet0=${num_jobs_nnet_array[0]}

! [ $num_epochs -gt 0 ] && echo "Error: num-epochs $num_epochs is not valid" && exit 1;

num_iters=$[($num_epochs*$num_archives0)/$num_jobs_nnet0]

echo "$0: Will train for $num_epochs epochs = $num_iters iterations (measured on model 0)"
# Work out the number of epochs we train for on the other models this is
# just informational.
for lang in $(seq 1 $[$num_lang-1]); do
  this_egs_dir=${all_egs_dir[$lang]}
  this_num_archives=${num_archives_array[$lang]}
  this_num_epochs=$[($num_iters*${num_jobs_nnet_array[$lang]})/$this_num_archives]
  echo "$0: $num_iters iterations is approximately $this_num_epochs epochs for language $lang"
done

if [ $stage -le -1 ]; then
  echo "$0: Copying initial models and modifying preconditioning setups"

  # Note, the baseline model probably had preconditioning, and we'll keep it;
  # but we want online preconditioning with a larger number of samples of
  # history, since in this setup the frames are only randomized at the segment
  # level so they are highly correlated.  It might make sense to tune this a
  # little, later on, although I doubt it matters once the --num-samples-history
  # is large enough.

  for lang in $(seq 0 $[$num_lang-1]); do
    $cmd $dir/$lang/log/convert.log \
      nnet-am-copy --learning-rate=$learning_rate ${src_model_array[$lang]} - \| \
      nnet-am-switch-preconditioning  --num-samples-history=50000 - $dir/$lang/0.mdl || exit 1;
  done
fi

# function to remove egs that might be soft links.
remove () { for x in $*; do [ -L $x ] && rm $(readlink -f $x); rm $x; done }

if [ $num_threads -eq 1 ]; then
  train_suffix="-simple" # this enables us to use GPU code if
                         # we have just one thread.
  num_gpu=1
else
  train_suffix="-parallel --num-threads=$num_threads"
  num_gpu=0
fi

#weights_csl=$(for lang in $(seq 0 $[num_lang-1]); do
#  perl -e "print ${num_jobs_nnet_array[$lang]} * ${learning_rate_scales_array[$lang]} . \" \""
#done | sed 's/ $//' | sed 's/ /:/g')

x=0   
while [ $x -lt $num_iters ]; do
  if [ $x -ge 0 ] && [ $stage -le $x ]; then
    
    echo "Training neural net (pass $x)"

    rm $dir/.error 2>/dev/null
    
    for lang in $(seq 0 $[$num_lang-1]); do
      this_num_jobs_nnet=${num_jobs_nnet_array[$lang]}
      this_num_archives=${num_archives_array[$lang]}
      this_egs_dir=${all_egs_dir[$lang]}
      this_silphonelist=${silphonelist_array[$lang]}
      this_obj=${objectives_array[$lang]}

      # The \$ below delays the evaluation of the expression until the script runs (and JOB
      # will be replaced by the job-id).  That expression in $[..] is responsible for
      # choosing the archive indexes to use for each job on each iteration... we cycle through
      # all archives.

      (
        if [ "$this_obj" == "ml" ]; then
          this_frames_per_eg=$(cat $this_egs_dir/info/frames_per_eg) || exit 1;
          ! [ $this_num_jobs_nnet -gt 0 -a $this_frames_per_eg -gt 0 -a $this_num_archives -gt 0 ] && exit 1
        
          for n in $(seq $this_num_jobs_nnet); do
            k=$[$x*$this_num_jobs_nnet + $n - 1]; # k is a zero-based index that we'll derive
            # the other indexes from.
            archive=$[($k%$this_num_archives)+1]; # work out the 1-based archive index.
            frame=$[(($k/$this_num_archives)%$this_frames_per_eg)];

            $cmd --num-threads $num_threads --gpu $num_gpu $dir/$lang/log/train.$x.$n.log \
              nnet-train$train_suffix \
              --minibatch-size=$minibatch_size --srand=$x \
              "nnet-am-copy --learning-rate-factor=${learning_rate_scales_array[$lang]} $dir/$lang/$x.mdl - |" \
              "ark:nnet-copy-egs --keep-proportion=1.0 --frame=$frame ark:$this_egs_dir/egs.$archive.ark ark:-|nnet-shuffle-egs --buffer-size=$shuffle_buffer_size --srand=$x ark:- ark:-|" \
              $dir/$lang/$[$x+1].$n.mdl || touch $dir/$lang/.error &
          done
          wait
          # the error message below is not that informative, but $cmd will
          # have printed a more specific one.
          [ -f $dir/$lang/.error ] && echo "$0: error on iteration $x of training in language $lang" && exit 1;
        elif [ "$this_obj" == "nce" ]; then
          $cmd --num-threads $num_threads --gpu $num_gpu JOB=1:$this_num_jobs_nnet $dir/$lang/log/train.$x.JOB.log \
            nnet-train-discriminative-unsupervised$train_suffix \
            --acoustic-scale=$acoustic_scale --verbose=2 \
            "nnet-am-copy --learning-rate-factor=${learning_rate_scales_array[$lang]} $dir/$lang/$x.mdl - |" \
            "ark:$this_egs_dir/uegs.\$[((JOB-1+($x*$this_num_jobs_nnet))%$this_num_archives)+1].ark" \
            $dir/$lang/$[$x+1].JOB.mdl || exit 1;
        else 
          $cmd --gpu $num_gpu --num-threads $num_threads JOB=1:$this_num_jobs_nnet $dir/$lang/log/train.$x.JOB.log \
            nnet-combine-egs-discriminative \
            "ark:$this_egs_dir/degs.\$[((JOB-1+($x*$this_num_jobs_nnet))%$this_num_archives)+1].ark" ark:- \| \
            nnet-train-discriminative$train_suffix --silence-phones=$this_silphonelist \
            --criterion=$this_obj --drop-frames=$drop_frames \
            --boost=$boost --acoustic-scale=$acoustic_scale \
            "nnet-am-copy --learning-rate-factor=${learning_rate_scales_array[$lang]} $dir/$lang/$x.mdl - |" \
            ark:- $dir/$lang/$[$x+1].JOB.mdl || exit 1;
        fi

        nnets_list=$(for n in $(seq $this_num_jobs_nnet); do echo $dir/$lang/$[$x+1].$n.mdl; done)
        # produce an average just within this language.
        $cmd $dir/$lang/log/average.$x.log \
          nnet-am-average $nnets_list $dir/$lang/$[$x+1].tmp.mdl || exit 1;

        rm $nnets_list
      ) || touch $dir/.error &
    done
    wait
    [ -f $dir/.error ] && echo "$0: error on pass $x" && exit 1
    
    nnets_list=$(for lang in $(seq 0 $[$num_lang-1]); do echo $dir/$lang/$[$x+1].tmp.mdl; done)

    # the next command produces the cross-language averaged model containing the
    # final layer corresponding to language zero.  Note, if we did modify-learning-rates,
    # it will also have the modified learning rates.
    $cmd $dir/log/average.$x.log \
      nnet-am-average --skip-last-layer=$skip_last_layer \
      $nnets_list $dir/0/$[$x+1].mdl || exit 1;
    
    # apply the modify-learning-rates thing to the model for the zero'th language;
    # we'll use the resulting learning rates for the other languages.
    if $modify_learning_rates; then
      $cmd $dir/log/modify_learning_rates.$x.log \
        nnet-modify-learning-rates --retroactive=$retroactive \
        --last-layer-factor=$last_layer_factor \
        --first-layer-factor=$first_layer_factor \
        $dir/0/$x.mdl $dir/0/$[$x+1].mdl $dir/0/$[$x+1].mdl || exit 1;
    fi

    if $separate_learning_rates; then 
      for lang in $(seq 1 $[$num_lang-1]); do
        # the next command takes the averaged hidden parameters from language zero, and
        # the last layer from language $lang.  It's not really doing averaging.
        $cmd $dir/$lang/log/combine_average.$x.log \
          nnet-am-average --weights=0.0:1.0 --skip-last-layer=$skip_last_layer \
          $dir/$lang/$[$x+1].tmp.mdl $dir/0/$[$x+1].mdl - \| \
          nnet-am-copy --inverse-learning-rate-factor=${learning_rate_scales_array[$lang]} - \
          $dir/$lang/$[$x+1].mdl || exit 1;
    
        if $modify_learning_rates; then
          $cmd $dir/$lang/log/modify_learning_rates.$x.log \
            nnet-modify-learning-rates --retroactive=$retroactive \
            --last-layer-factor=$last_layer_factor \
            --first-layer-factor=$first_layer_factor \
            $dir/$lang/$x.mdl $dir/$lang/$[$x+1].mdl $dir/$lang/$[$x+1].mdl || exit 1;
        fi
      done
    else
      # we'll transfer these learning rates to the other models.
      learning_rates=$(nnet-am-info --print-learning-rates=true $dir/0/$[$x+1].mdl 2>/dev/null)        

      for lang in $(seq 1 $[$num_lang-1]); do
        # the next command takes the averaged hidden parameters from language zero, and
        # the last layer from language $lang.  It's not really doing averaging.
        # we use nnet-am-copy to transfer the learning rates from model zero.
        $cmd $dir/$lang/log/combine_average.$x.log \
          nnet-am-average --weights=0.0:1.0 --skip-last-layer=$skip_last_layer \
          $dir/$lang/$[$x+1].tmp.mdl $dir/0/$[$x+1].mdl - \| \
          nnet-am-copy --learning-rates=$learning_rates - $dir/$lang/$[$x+1].mdl || exit 1;
      done
    fi

    $cleanup && rm $dir/*/$[$x+1].tmp.mdl

  fi

  x=$[$x+1]
done

for lang in $(seq 0 $[$num_lang-1]); do
  rm $dir/$lang/final.mdl 2>/dev/null
  ln -s $x.mdl $dir/$lang/final.mdl


  epoch_final_iters=
  for e in $(seq 0 $num_epochs); do
    x=$[($e*$num_archives0)/$num_jobs_nnet0] # gives the iteration number.
    ln -sf $x.mdl $dir/$lang/epoch$e.mdl
    epoch_final_iters="$epoch_final_iters $x"
  done

  if $cleanup; then
    echo "Removing most of the models for language $lang"
    for x in `seq 0 $num_iters`; do
      if ! echo $epoch_final_iters | grep -w $x >/dev/null; then 
        # if $x is not an epoch-final iteration..
        rm $dir/$lang/$x.mdl 2>/dev/null
      fi
    done
  fi
done

echo Done
