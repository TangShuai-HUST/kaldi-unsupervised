#!/bin/bash

. conf/common_vars.sh
. ./lang.conf

set -e
set -o pipefail
set -u

degs_dir=
criterion=smbr

. utils/parse_options.sh

# Wait for cross-entropy training.
echo "Waiting till exp/tri6_nnet/.done exists...."
while [ ! -f exp/tri6_nnet/.done ]; do sleep 30; done
echo "...done waiting for exp/tri6_nnet/.done"

# Generate denominator lattices.
if [ ! -f exp/tri6_nnet_denlats/.done ]; then
  steps/nnet2/make_denlats.sh "${dnn_denlats_extra_opts[@]}" \
    --nj $train_nj --sub-split $train_nj \
    --transform-dir exp/tri5_ali \
    data/train data/lang exp/tri6_nnet exp/tri6_nnet_denlats || exit 1
 
  touch exp/tri6_nnet_denlats/.done
fi

# Generate alignment.
if [ ! -f exp/tri6_nnet_ali/.done ]; then
  steps/nnet2/align.sh --use-gpu yes \
    --cmd "$decode_cmd $dnn_parallel_opts" \
    --transform-dir exp/tri5_ali --nj $train_nj \
    data/train data/lang exp/tri6_nnet exp/tri6_nnet_ali || exit 1

  touch exp/tri6_nnet_ali/.done
fi

lang=`echo $train_data_dir | perl -pe 's:.+data/\d+-([^/]+)/.+:$1:'`

if [[ `hostname -f` == *.clsp.jhu.edu ]]; then
  # spread the egs over various machines. 
  [ -z "$degs_dir" ] && utils/create_split_dir.pl /export/b0{1,2,3,4}/$USER/kaldi-data/egs/babel_${lang}_s5b-$(date '%d_%m_%H_%M')/exp/tri6_nnet_${criterion}/degs exp/tri6_nnet_${criterion}/degs/storage 
fi

if [ -z "$degs_dir" ]; then
  if [ ! -f exp/tri6_nnet_${criterion}/.degs.done ]; then
    steps/nnet2/get_egs_discriminative2.sh --cmd "$decode_cmd --max-jobs-run 10" \
      --criterion $criterion --drop-frames true \
      --transform-dir exp/tri5_ali \
      data/train data/lang \
      exp/tri6_nnet_ali exp/tri6_nnet_denlats \
      exp/tri6_nnet/final.mdl exp/tri6_nnet_${criterion}/degs || exit 1
    touch exp/tri6_nnet_${criterion}/.degs.done
  fi
  degs_dir=exp/tri6_nnet_${criterion}/degs
fi

train_stage=-100
if [ ! -f exp/tri6_nnet_${criterion}/.done ]; then
  steps/nnet2/train_discriminative2.sh \
    --criterion $criterion \
    --stage $train_stage --cmd "$decode_cmd --num-threads 16" \
    --learning-rate $dnn_mpe_learning_rate \
    --modify-learning-rates true \
    --last-layer-factor $dnn_mpe_last_layer_factor \
    --num-epochs 4 --cleanup false \
    --retroactive $dnn_mpe_retroactive \
    "${dnn_cpu_mpe_parallel_opts[@]}" \
    $degs_dir exp/tri6_nnet_${criterion} || exit 1

  touch exp/tri6_nnet_${criterion}/.done
fi
