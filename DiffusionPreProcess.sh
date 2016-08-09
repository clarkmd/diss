#! /bin/bash

#First, check to be sure a subject list has been given as the first argument. This should be a file with the subject numbers "s001" given in a single column
# Second, check to see what steps are to be completed.

if [ $# -lt 2 ]
  then
    echo "Argument 1: subject list "
    echo "Argument 2: which step(s) do you want to do?"
	echo "Step 1: opens the .zip file from PACS"
	echo "Step 2: make NODDI nii and put it through DTIPrep QC protocol"
	echo "arg2: 3->skip to eddy correction"
	echo "arg2: 4->skip to bvec rotation"
	echo "arg2: 5->skip to bet"
	echo "arg2: 6->skip to dtifit"
	echo "add 1 in third argument to just perform the step indicated in argument 2..."
	echo "if using this option, be sure to pay attention to the SubjectList.txt file as this will still cycle through all of the subjects in that file."	
fi

#SubjDir should contain all of the subjects' top directories
SubjDir=/home/clarkmd/dissertation
DwiDir=$SubjDir/$subj/dwi

#This will create a steps.txt file that has a column with entries of i to $2
#This file will be used by the script to read in each step and perform it successively by checking a bunch of elif statements. 
#This is probably a very not-so-efficient way to add modularity to the script. 
#If I think of something better, I'll change it, otherwise, just deal.
i=$2
for a in 6 5 4 3 2 1 0; do
if [ $3 -eq 1 ]
then 
echo $2 > $SubjDir/steps.txt
else
if [ $(($i-$a)) -gt 0 ]
then
echo $(($i-$a)) >> $SubjDir/steps.txt
fi
fi
done
#This while loop goes through the SubjectsList.txt file and does each subject one at a time through the steps given in $2
while read subj
do
   echo "Processing subject $subj"

#This while loop reads steps.txt
while read steps
do

echo "Performing step $steps"
cd $SubjDir/$subj

#Logs to track down any f-ups in the script
LOGS=$SubjDir/$subj/LOGS
mkdir -p $LOGS

#first step: unzip, convert dcm to nii, and organize files
if [ $steps -eq 1 ]
        then 
{
unzip *.zip
} &>/dev/null
mv *.zip ${subj}.zip
{
dcm2nii -4 -g -n -p -o new *
} &>$LOGS/dcm2nii

#This part organizes the output from dcm2nii
#need to be sure the dcm2nii.ini file has the correct settings, i.e. the naming of the files is only the protocol name (or something like that, check the .ini).
mkdir -p dwi Localizer structural resting misc dwi/misc resting/misc task dicoms
mv *dcm dicoms
#These are the TRACE, FA, ColFA, and ADC files from the scanner. Don't need themright now.
mv *b700[ABCD]* dwi/misc
mv *b300[ABCD]* dwi/misc
mv *b2000[ABCD]* dwi/misc
#These are the DWI files. These will be merged and used for NODDI and TBSS
mv *b300* dwi
mv *b700* dwi
mv *b2000* dwi
mv localizer* Localizer
#will need to get these in shape later.
mv *t1* *t2* structural
mv *Connectivity[ABC]* resting/misc
mv *Connectivity* resting
mv *17meas* task

###DIFFUSION PREPROCESSING###
#Step 2 begins the actual preprocessing.
elif [ $steps -eq 2 ]
then
DwiDir=$SubjDir/$subj/dwi
cd $DwiDir

#This puts the three DWI acquisitions together - For use in NODDI 
#It also combines the bval and bvec files to correspond to the new 4D
###NOTE: These files need to be transposed in order for DTIPrep to read them properly

if [ -a dwi.nii.gz ]
then
echo "dwi.nii.gz already exists for subject $subj"
else
echo "merging dwi files for $subj for use in NODDI"
echo "making Bvec and Bval files for NODDI"
fslmerge -t dwi.nii.gz *b300*nii* *b700*nii* *b2000*nii*
paste -d" " *b300.bval *b700.bval *b2000.bval > NODDIbvals.all
paste -d" " *b300.bvec *b700.bvec *b2000.bvec > NODDIbvecs.all
fi

######Quality Control######
#Convert nii.gz to nrrd
#feed into DTIPrep QC protocol

bscale300=`echo "sqrt ( 300/2000 )"|bc -l`
transpose.sh *b300.bvec > t300bvec
awk '{x='$bscale300'*$1; y='$bscale300'*$2; z='$bscale300'*$3; print x, y, z}' t300bvec > DTIPrepbvecs
transpose.sh *b700.bvec > t700bvec
bscale700=`echo "sqrt ( 700/2000 )"|bc -l`
awk '{x='$bscale700'*$1; y='$bscale700'*$2; z='$bscale700'*$3; print x, y, z}' t700bvec >> DTIPrepbvecs

transpose.sh *b2000.bvec > t2000bvec

cat t2000bvec >> DTIPrepbvecs

rm t300bvec t700bvec t2000bvec

transpose.sh NODDIbvals.all > Tbvals.all

DWIConvert --inputBVectors DTIPrepbvecs --inputBValues Tbvals.all -o ./${subj}.nrrd --inputVolume dwi.nii.gz --conversionMode FSLToNrrd




#This processes the NODDI dwi file... NEED TO ADD FUGUE TO THIS WHEN WE GET FIELD MAPS

elif [ $steps -eq 3 ]
then
echo "eddy correcting NODDI image"
echo "NEED TO ADD FUGUE BEFORE DTIFIT 3-25-16"
{
eddy_correct $DwiDir/dwi.nii.gz $DwiDir/ecdwi.nii.gz 0
} &> $LOGS/eddy_correct

###Adjust Bvecs file after eddy correction. Again for NODDI file

elif [ $steps -eq 4 ]
then
#Originally written by Saad Jbabdi
# University of Oxford, FMRIB Centre
# and posted on JISCMail FSL Archives Feb 3 2012
# modified by Neda Jahanshad (USC/ENIGMA-DTI)
# to take in vertically oriented bvec files

DwiDir=$SubjDir/$subj/dwi
Bvec=$DwiDir/NODDIbvecs.all
Ecclog=$DwiDir/ecdwi.ecclog
LOGS=$SubjDir/$subj/LOGS
#if [ "$3" == "" ] ; then 
# echo "Usage: <original bvecs> <rotated bvecs> <ecclog>"
# echo ""
# echo "<ecclog>	is the output log file from ecc"
# echo ""
# exit 1;
#fi

i=$Bvec
o=$DwiDir/NODDIrot_bvecs.all
ecclog=$Ecclog
{
if [ ! -e $i ] ; then
	echo "Source bvecs for $subj does not exist!"
	exit 1
fi
if [ ! -e $ecclog ]; then
	echo "Ecc log file for $subj does not exist!"
	exit 1
fi

nline=$(cat $i | wc -l )
if [ $nline -gt 3 ]
then
echo "the file is vertical and will be transposed"
awk '
{
for (k=1; k<=NF; k++)  {
a[NR,k] = $k
}
}
NF>p { p = NF }
END {
for(j=1; j<=p; j++) {
str=a[1,j]
for(k=2; k<=NR; k++){
str=str" "a[k,j];
}
print str
}
}' $i > ${i}_horizontal

i=${i}_horizontal
fi



ii=1
rm -f $o
tmpo=${o}$$
cat ${ecclog} | while read line; do
    echo $ii
    if [ "$line" == "" ];then break;fi
    read line;
    read line;
    read line;

    echo $line  > $tmpo
    read line    
    echo $line >> $tmpo
    read line    
    echo $line >> $tmpo
    read line    
    echo $line >> $tmpo
    read line   
    
    m11=`avscale $tmpo | grep Rotation -A 1 | tail -n 1| awk '{print $1}'`
    m12=`avscale $tmpo | grep Rotation -A 1 | tail -n 1| awk '{print $2}'`
    m13=`avscale $tmpo | grep Rotation -A 1 | tail -n 1| awk '{print $3}'`
    m21=`avscale $tmpo | grep Rotation -A 2 | tail -n 1| awk '{print $1}'`
    m22=`avscale $tmpo | grep Rotation -A 2 | tail -n 1| awk '{print $2}'`
    m23=`avscale $tmpo | grep Rotation -A 2 | tail -n 1| awk '{print $3}'`
    m31=`avscale $tmpo | grep Rotation -A 3 | tail -n 1| awk '{print $1}'`
    m32=`avscale $tmpo | grep Rotation -A 3 | tail -n 1| awk '{print $2}'`
    m33=`avscale $tmpo | grep Rotation -A 3 | tail -n 1| awk '{print $3}'`

    X=`cat $i | awk -v x=$ii '{print $x}' | head -n 1 | tail -n 1 | awk -F"E" 'BEGIN{OFMT="%10.10f"} {print $1 * (10 ^ $2)}' `
    Y=`cat $i | awk -v x=$ii '{print $x}' | head -n 2 | tail -n 1 | awk -F"E" 'BEGIN{OFMT="%10.10f"} {print $1 * (10 ^ $2)}' `
    Z=`cat $i | awk -v x=$ii '{print $x}' | head -n 3 | tail -n 1 | awk -F"E" 'BEGIN{OFMT="%10.10f"} {print $1 * (10 ^ $2)}' `
    rX=`echo "scale=7;  ($m11 * $X) + ($m12 * $Y) + ($m13 * $Z)" | bc -l`
    rY=`echo "scale=7;  ($m21 * $X) + ($m22 * $Y) + ($m23 * $Z)" | bc -l`
    rZ=`echo "scale=7;  ($m31 * $X) + ($m32 * $Y) + ($m33 * $Z)" | bc -l`

    if [ "$ii" -eq 1 ];then
	echo $rX > $o;echo $rY >> $o;echo $rZ >> $o
    else
	cp $o $tmpo
	(echo $rX;echo $rY;echo $rZ) | paste $tmpo - > $o
    fi
    
    let "ii+=1"

done
} &>$LOGS/bvecrotation
rm -f $tmpo

elif [ $steps -eq 5 ]
then
LOGS=$SubjDir/$subj/LOGS
DwiDir=$SubjDir/$subj/dwi
echo "bet on $subj"

bet2 $DwiDir/ecdwi.nii.gz $DwiDir/bet -m -f 0.16

elif [ $steps -eq 6 ]
then

DwiDir=$SubjDir/$subj/dwi
LOGS=$SubjDir/$subj/LOGS
echo "fitting tensor on $subj"
{
dtifit -k $DwiDir/ecdwi.nii.gz -o $DwiDir/$subj -m $DwiDir/bet_mask -r $DwiDir/NODDIrot_bvecs.all -b $DwiDir/NODDIbvals.all
} &>$LOGS/dtifit

#This next step processes the b700 images for use in TBSS.

elif [ $steps -eq 7 ]
then
LOGS=$SubjDir/$subj/LOGS
DwiDir=$SubjDir/$subj/dwi

echo "Prepping b700 DTI image for TBSS"
{
eddy_correct $DwiDir/*b700.nii.gz $DwiDir/ec700dwi.nii.gz 0
} &> $LOGS/eddy_correct_b700

###rotate the bvecs###
DwiDir=$SubjDir/$subj/dwi
Bvec=$DwiDir/*b700.bvec
Ecclog=$DwiDir/ec700dwi.ecclog
LOGS=$SubjDir/$subj/LOGS
#if [ "$3" == "" ] ; then 
# echo "Usage: <original bvecs> <rotated bvecs> <ecclog>"
# echo ""
# echo "<ecclog>	is the output log file from ecc"
# echo ""
# exit 1;
#fi

i=$Bvec
o=$DwiDir/rot_bvecs.700
ecclog=$Ecclog
{
if [ ! -e $i ] ; then
	echo "Source bvecs for $subj does not exist!"
	exit 1
fi
if [ ! -e $ecclog ]; then
	echo "Ecc log file for $subj does not exist!"
	exit 1
fi

nline=$(cat $i | wc -l )
if [ $nline -gt 3 ]
then
echo "the file is vertical and will be transposed"
awk '
{
for (k=1; k<=NF; k++)  {
a[NR,k] = $k
}
}
NF>p { p = NF }
END {
for(j=1; j<=p; j++) {
str=a[1,j]
for(k=2; k<=NR; k++){
str=str" "a[k,j];
}
print str
}
}' $i > ${i}_horizontal

i=${i}_horizontal
fi

ii=1
rm -f $o
tmpo=${o}$$
cat ${ecclog} | while read line; do
    echo $ii
    if [ "$line" == "" ];then break;fi
    read line;
    read line;
    read line;

    echo $line  > $tmpo
    read line    
    echo $line >> $tmpo
    read line    
    echo $line >> $tmpo
    read line    
    echo $line >> $tmpo
    read line   
    
    m11=`avscale $tmpo | grep Rotation -A 1 | tail -n 1| awk '{print $1}'`
    m12=`avscale $tmpo | grep Rotation -A 1 | tail -n 1| awk '{print $2}'`
    m13=`avscale $tmpo | grep Rotation -A 1 | tail -n 1| awk '{print $3}'`
    m21=`avscale $tmpo | grep Rotation -A 2 | tail -n 1| awk '{print $1}'`
    m22=`avscale $tmpo | grep Rotation -A 2 | tail -n 1| awk '{print $2}'`
    m23=`avscale $tmpo | grep Rotation -A 2 | tail -n 1| awk '{print $3}'`
    m31=`avscale $tmpo | grep Rotation -A 3 | tail -n 1| awk '{print $1}'`
    m32=`avscale $tmpo | grep Rotation -A 3 | tail -n 1| awk '{print $2}'`
    m33=`avscale $tmpo | grep Rotation -A 3 | tail -n 1| awk '{print $3}'`

    X=`cat $i | awk -v x=$ii '{print $x}' | head -n 1 | tail -n 1 | awk -F"E" 'BEGIN{OFMT="%10.10f"} {print $1 * (10 ^ $2)}' `
    Y=`cat $i | awk -v x=$ii '{print $x}' | head -n 2 | tail -n 1 | awk -F"E" 'BEGIN{OFMT="%10.10f"} {print $1 * (10 ^ $2)}' `
    Z=`cat $i | awk -v x=$ii '{print $x}' | head -n 3 | tail -n 1 | awk -F"E" 'BEGIN{OFMT="%10.10f"} {print $1 * (10 ^ $2)}' `
    rX=`echo "scale=7;  ($m11 * $X) + ($m12 * $Y) + ($m13 * $Z)" | bc -l`
    rY=`echo "scale=7;  ($m21 * $X) + ($m22 * $Y) + ($m23 * $Z)" | bc -l`
    rZ=`echo "scale=7;  ($m31 * $X) + ($m32 * $Y) + ($m33 * $Z)" | bc -l`

    if [ "$ii" -eq 1 ];then
	echo $rX > $o;echo $rY >> $o;echo $rZ >> $o
    else
	cp $o $tmpo
	(echo $rX;echo $rY;echo $rZ) | paste $tmpo - > $o
    fi
    
    let "ii+=1"

done
} &>$LOGS/bvecrotation700
rm -f $tmpo

echo "bet for b700 on $subj"

bet2 $DwiDir/ec700dwi.nii.gz $DwiDir/bet700 -m -f 0.16

DwiDir=$SubjDir/$subj/dwi
LOGS=$SubjDir/$subj/LOGS
echo "fitting tensor on b700 for $subj"
mkdir -p $DwiDir/TBSS

{
dtifit -k $DwiDir/ec700dwi.nii.gz -o $DwiDir/TBSS/$subj -m $DwiDir/bet700_mask -r $DwiDir/rot_bvecs.700 -b $DwiDir/*b700.bval
} &>$LOGS/dtifit700

fi
done < $SubjDir/steps.txt
done < $SubjDir/$1
rm $SubjDir/steps.txt

###And now time for some Quality Control###
#Nifti to Nrrd


