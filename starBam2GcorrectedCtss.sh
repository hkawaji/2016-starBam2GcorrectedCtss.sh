#!/bin/sh

set -ue

function usage()
{
  cat <<EOF

$(basename $0)  Version 0.1 (May 31, 2016)
===============================
Convert BAM file to CTSS bed, where additional G is corrected
based on the supplementary note 3e of Nature genet 38:626-35.

Note that handling of 'additional G' depends on aligners (and their options).
This script is developed for STAR (https://github.com/alexdobin/STAR)
'--alignEndsType Local' (default), which is different from default behavior
of TopHat and BWA-SW.


Usage
-----

  $0 -i SORTED.bam -c CHROM_SIZE -g GENOME_SEQ -q MAPPING_QUALITY

- SORTED.bam: alignment file produced by STAR
- CHROM_SIZE: chrom_size file, which is the used by BEDtools
- GENOME_SEQ: fasta file of the genome.
- MAPPING_QUALITY: threshold for mapping quality.


Output
------
The output is formatted as BED (for CTSS), where names represent internal scores
and the score represent the corrected counts.


Definition for interpretation
-----------------------------
For the entire profile,
- P: the chance of adding a 'G' (one value for the entire profile)

For each entry (alignment):
- X: observed read counts corresponding to the CTSS (this can be obtained from BAM entry)
- A0: counts of reads that are observed in this CTSS, with extra G mismatching to the genome (this can be obtained immediately from BAM entry)
- A:  counts of reads that are obserbed in this CTSS, with extra G.
- N:  corrected read counts corresponding to the CTSS
- U:  counts of reads that are obserbed in this CTSS, without extra G. 
- F:  the counts of reads that are obserbed in this CTSS but expected to belong to the next (1bp downstream) CTSS

State (example: 'HHHGGGHH' - H represent a base of non-G):
- S: start case (4th base, in the exammple above)
- G: generic case (5th, 6th base)
- E: end case (7th base)
- O: other case (1-3rd,8th base)


Requirements:
-------------
- bedtools
- samtools


Credit
----
- Author: Hideya Kawaji <kawaji@gsc.riken.jp>
- Copyright: RIKEN, Japan.

EOF
  exit 1;
}

###
### set up options and tmpdir
### (default score for g_addition_ratio is based on Nature genet 38:626-35.)
###
infile=
chrom_size=
genome=
mapQ=20
g_addition_ratio=0.8935878

while getopts i:c:g:q:r: opt
do
  case ${opt} in
  i) infile=${OPTARG};;
  c) chrom_size=${OPTARG};;
  g) genome=${OPTARG};;
  q) mapQ=${OPTARG};;
  r) g_addition_ratio=${OPTARG};;
  *) usage;;
  esac
done

for x in infile chrom_size genome
do
  if [ "$( eval echo \$$x )" = "" ];then usage; fi
done

tmpdir=$(mktemp -d -p ${TMPDIR:-/tmp})
trap "[[ $tmpdir ]] && rm -rf $tmpdir" 0 1 2 3 15



###
### subroutine
###


# select SAM entries (alignments) containing additional 'G'
# ----------
# (standard) input: sam, generated by STAR
# (standard) output: sam (only entries with additionalG)
#
function samWithAdditionalG ()
{
  awk 'BEGIN{ FS="\t"; OFS="\t" }
  {
    if (/^@/){ print; next }
    flag  = $2; cigar = $6; seq = $10;

    if ( and($2, 16) == 0 ) {
      if ( match( cigar , /^[[:digit:]]+S/ ) )
      {
        str = toupper( substr( cigar, RSTART, RLENGTH - 1) )
        if ( substr( seq, str - 1, 1) == "G" ) {print $0}
        next
      }
    }

    if ( and($2, 16) == 16 ) {
      if ( match( cigar , /[[:digit:]]+S$/ ) )
      {
        str = toupper( substr( cigar, RSTART, RLENGTH - 1) )
        if ( substr( seq, length(seq) - (str - 1) , 1) == "C" ) {print $0}
        next
      }
    }
  }'
}


# make union of bedGraph for 'X' and 'A0'
# ---------------------------------------
# (standard) input: sam, generated by STAR
# (standard) output: bed chrom, start, end, X, A0, and Nuc
#
function bgXA0Nuc ()
{
  local strand=$1
  local fileX=${tmpdir}/tmp${strand}.X.bg
  local fileA0=${tmpdir}/tmp${strand}.A0.bg
  local fileCS=${tmpdir}/chrom_size.bed

  cat ${chrom_size} \
  | awk 'BEGIN{FS="\t";OFS="\t"}{print $1,0,$2}' \
  | sort -k1,1 \
  > $fileCS

  samtools view -u -F 0x100 -q $mapQ ${infile} \
  | bamToBed -i stdin \
  | genomeCoverageBed -strand ${strand} -5 -bg -g ${chrom_size} -i stdin \
  | sort -k1,1 -k2,2n \
  > ${fileX} &

  samtools view -h -F 0x100 -q $mapQ ${infile} \
  | samWithAdditionalG \
  | samtools view -u - \
  | bamToBed -i stdin \
  | genomeCoverageBed -strand ${strand} -5 -bg -g ${chrom_size} -i stdin \
  | sort -k1,1 -k2,2n \
  > ${fileA0}  &

  wait

  unionBedGraphs -i ${fileX} ${fileA0} \
  | awk 'BEGIN{OFS="\t";FS="\t";pEnd="";pChrom=""}
    {
      # init
      chrom = $1; start = $2; end = $3;

      # put up/downstream base to clarify state
      if ((chrom != pChrom) || (pEnd != start)) {
        if ((chrom != pChrom) || (pEnd != (start - 1)))
          { if(pChrom != ""){ print pChrom, pEnd , pEnd + 1, 0, 0 } }
        if (start > 0)
          { print chrom, start - 1, start, 0, 0 }
      }

      # put entry per base
      for(i = start; i < end ; i = i+1)
        { $2 = i ; $3 = i + 1;print $0; }

      # post process
      pEnd = end; pChrom = chrom;
    }' \
  | intersectBed -wa -u -a stdin -b $fileCS \
  | nucBed -seq -fi ${genome} -bed stdin \
  | cut -f 1-5,15 | grep -v ^#
}


# G correction
# -------------
# (standard) input: bed chrom, start, end, X, A0, and Nuc
# (standard) output: bed chrom, start, end, INTERNAL_STATES, N(corrected counts)
function gCorrection ()
{
  # strand: "+" or "-"
  local strand=$1

  awk --assign P=$g_addition_ratio --assign strand=$strand 'BEGIN{
    FS="\t";OFS="\t"
    pChrom = ""; pStart = ""; pEnd = "";
    pA = ""; pN = ""; pU = ""; pF = ""; pNuc = "";
  }{
    ### read
    chrom = $1; start = $2; end = $3;
    X     = $4; A0    = $5; Nuc = $6;

    ### set
    if ( (strand == "+") && ((pChrom != chrom) || (pEnd != start)) ){
      state = "O" # other
      A = A0; N = X ; U = N - A; F = 0;
    } else if ( (strand == "-") && ((pChrom != chrom) || (pStart != end)) ){
      state = "O" # other
      A = A0; N = X ; U = N - A; F = 0;
    } else if ( ( pNuc != "G" ) && ( Nuc == "G") ) {
      state = "S" # start
      A = A0
      N = A / P; if ( N > X ) {N = X}
      U = (A / P) * ( 1 - P )
      F = X - A - U; if (F < 0) {F = 0}; if (F > X){ F = X}
    } else if ( (pNuc == "G") && ( Nuc == "G") ) {
      state = "G" # general
      A = pF
      N = A / P; if ( N > (A + X) ) {N = A + X}
      U = (A / P) * ( 1 - P )
      F = X - U; if (F < 0) {F = 0}; if (F > X){ F = X}
    } else if ( (pNuc == "G") && ( Nuc != "G" ) ) {
      state = "E" # end
      A = pF
      N = A + X
      U = X
      F = 0
    } else {
      state = "O" # other
      A = A0; N = X ; U = N - A; F = 0;
    }
    F = sprintf("%i", F)
    pChrom = chrom; pStart = start; pEnd = end;
    pA = A; pN = N; pU = U; pF = F; pNuc = Nuc;

    ### print
    n = sprintf("X:%.2f,A0:%.2f,Nuc:%s,State:%s,A:%.2f,N:%.2f,U:%.2f,F:%.2f",X,A0,Nuc,state,A,N,U,F)
    printf("%s\t%i\t%i\t%s\t%i\n", chrom, start, end, n, N)
  }'
}



###
### main
###


# forward
bgXA0Nuc + \
| gCorrection + \
| awk 'BEGIN{OFS="\t"}{print $1,$2,$3,$4,$5,"+"}' \
> ${tmpdir}/res.fwd.bed &

# reverse
bgXA0Nuc - \
| sort -k1,1 -k2,2nr \
| awk 'BEGIN{c["A"]="T";c["T"]="A";c["C"]="G";c["G"]="C";OFS="\t"}{print $1,$2,$3,$4,$5,c[toupper($6)]}' \
| gCorrection - \
| awk 'BEGIN{OFS="\t"}{print $1,$2,$3,$4,$5,"-"}' \
> ${tmpdir}/res.rev.bed &

wait

cat \
  ${tmpdir}/res.fwd.bed \
  ${tmpdir}/res.rev.bed \
| sort -k1,1 -k2,2n



