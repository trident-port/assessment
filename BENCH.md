# Measuring copy speed and estimating the migration time

This is an optional step inside the assessment. It measures how fast a copy runs on your cluster. Then it adds tables of how long the migration would take to the summary of the assessment.

One command does all of it.

```sh
./tp-pre.sh --bench --dest-sc <your Trident class>
```

Three files work together. Keep them in the same directory.

- `tp-pre.sh` is the assessment. It starts the rest when you pass `--bench`.
- `tp-bench.sh` measures. It creates things in your cluster, so it does nothing unless it is given `--bench`.
- `tp-estimate` reads the assessment and the measurement and writes the tables. It needs only Python 3. It does not contact the cluster.

## What it does

`--bench` checks that it can run. Then it writes test data into a volume of each source class and copies it to volumes of the destination class. It uses the same `rsync` options the product uses. It times every copy.

It measures four kinds of data, each on its own.

- Large: 4 files of 10 GiB. They are at least twice the memory of the copy pod, so the cache cannot hold them.
- Medium: 1,000 files of 1 to 16 MiB.
- Small: 1,000,000 files of 1 to 8 KiB, in a tree of directories 4 to 6 levels deep.
- Mixed: a share of the three together.

It copies the large and the small data with 1, 4, 8 and 16 copies at the same time. That shows where the storage stops giving more. Each measurement is repeated. The report gives the number of repetitions and the spread between them. A high spread is said out loud.

During every run it reads the CPU and the memory of the node and the memory of the pod. That tells whether the limit is the node.

After the first copy of the medium, small and mixed data it changes 1 percent and then 10 percent of the files and copies again. That last pass is what a live sync does before a cutover. It is the length of the cutover window.

It also tests file ownership on the destination. It writes a file as `0:0` and reads it back. If the destination turns the owner into `nobody`, the result says so. Some NFSv4 setups do this. The applications then lose access to their files.

## How the time is worked out

The time of a volume comes from two measured numbers.

- Bytes per second, from the large data.
- Seconds per file, from the small data.

Time = bytes divided by bytes per second, plus files times seconds per file. The estimate uses the real size and the real number of files of each volume from the assessment. The medium and the mixed data are used to adjust the two numbers. The report prints the error of that adjustment for every kind of data.

## What it creates

Everything lives in one namespace called `tp-bench`.

- The namespace `tp-bench`.
- One claim in each source class. For the default size it is about 75 GiB, with about 60 GiB of test data in it.
- Up to 16 claims in the destination class. There is one for each simultaneous copy.
- One pod for the ownership test, and one pod for each source class. They run one at a time. Each pod has a memory limit of 2 GiB.

Before it creates anything, it prints how much space it will use in the source and in the destination and how long it may take. Then it asks for confirmation. Pass `--yes` to skip the question.

The test data is random bytes created by the script. It is not compressible and not duplicated.

## What it deletes

When it ends, it deletes the namespace `tp-bench` by name. That removes the pods and the claims. It does this also when a step fails and when you press Ctrl-C.

It touches nothing else. If a namespace called `tp-bench` already exists and this script did not create it, the script stops and changes nothing.

One case needs your attention. Some storage classes keep the volume after the claim is gone (reclaim policy Retain). The script lists those volumes by name and leaves them. It does not delete data on the array. Ask your storage administrator whether they can go.

## What it checks first

Before it creates anything, it checks four things. If one fails, it says what is missing and the exact command to fix it.

- The storage classes exist. If the destination class does not exist, it lists the classes served by Trident, or says that you must create the backend and the class first.
- The account may create and delete the namespace, and create pods and claims in it.
- The image can be pulled. If it cannot, the message says how to give it another image.
- A quota in the namespace is shown, with what the run needs.

## What permissions it needs

The account needs to do these in the cluster.

- Create and delete the namespace `tp-bench`.
- Create and delete pods and claims inside it.
- Read pod logs inside it.
- Read storage classes and persistent volumes.

On OpenShift the pods run under the `restricted-v2` constraint. They run as an ordinary user chosen by OpenShift. They ask for no extra constraint, no root and no privileges.

That has one cost. The ownership test needs root to change an owner, so by default it can only report what an ordinary user can see. It says so in the result. To run the full ownership test, add `--run-as-root`. An administrator must then allow root in `tp-bench`. The script prints the exact command and waits for you. The permission is removed with the namespace.

Some NFS destinations may let only root write at the top of a new volume. Then the pods cannot write as an ordinary user. The result says that the destination refused the write. Run again with `--run-as-root`.

## How long it takes

It depends on the storage. The script prints a guess before it starts. The guess assumes 100 MiB/s and 1,500 files/s for each copy. The real time can be several times more or less.

- The default size is guessed at about five hours for each source class.
- A smaller size is faster and gives rougher numbers. Use `--bench-size small`.
- A larger size needs more space and more time. Use `--bench-size large`.
- Pulling the image can add a few minutes the first time.

The script prints a progress line while it works. The default limit is 10 hours for each source class.

## How to run it

You need `bash`, `python3`, and `kubectl` or `oc` logged in to the cluster. The image that runs the pods needs `rsync`, `bash` and `python3`. The Trident Port image has them.

For an assessment with a file count for every volume, which makes the estimate more exact, run this:

```sh
./tp-pre.sh --count-files --bench --dest-sc <your Trident class>
```

To choose the source classes yourself:

```sh
./tp-pre.sh --bench --dest-sc <your Trident class> --source-sc <class-1>,<class-2>
```

To choose how much data is written:

```sh
./tp-pre.sh --bench --dest-sc <your Trident class> --bench-size small
```

If the cluster has no route to the internet, pass the image your mirror holds:

```sh
./tp-pre.sh --bench --dest-sc <your Trident class> --bench-image <registry>/<path>/trident-port:<tag>
```

To see the plan without creating anything, run the measuring script alone without `--bench`:

```sh
bash tp-bench.sh --source-sc <class-1>,<class-2> --dest-sc <your Trident class>
```

All options are listed by `./tp-pre.sh --help`, `bash tp-bench.sh --help` and `python3 tp-estimate --help`.

## What the estimate contains

The tables are added to the summary of the assessment, under the heading Migration times.

- One row for each volume: size, number of files, and the time to copy it.
- One row for each namespace: the time of a cold copy with the applications stopped, the time of the first copy of a live sync with the applications running, and the cutover window with 1 percent and with 10 percent of the files changed.
- One block for the whole cluster with three scenarios: optimistic (16 copies at once), expected (4 at once) and pessimistic (everything one after another, plus 50 percent). It also names the largest volume, which sets the shortest possible total.
- What was measured for each kind of data, with repetitions and spread, the error of the model, and where more copies at once stop giving more.

Every figure says where it comes from.

- **measured**: a rate that `tp-bench.sh` measured on your cluster.
- **read**: a size or a count from the assessment, or a constant of the product.
- **assumed**: a choice, with the choice written next to it.
- **unknown**: nothing could be said. No number is invented.

If the number of files of a volume is unknown, that volume is priced as if it held the smallest files that were measured. This is the slow case. It is marked as assumed.

## What the estimate cannot tell

- How much your applications write while the first copy runs. The cutover window is given for 1 and for 10 percent of the files changed. The real share is yours to judge.
- The speed of a volume that behaves unlike the test volume. The test uses one volume of each class.
- The effect of other load on the storage during the real migration.
- Whether a limit is the network or the array. The report says when the node is not the limit.
- All simultaneous copies run in one pod on one node. Copies spread over several nodes may add up to more.

## What to send back to NetApp

Send the archive `tp-pre-<context>-<date>.tgz`. It holds the assessment, the measurement and the tables. None of it holds data from your volumes. The files in it are:

- the assessment: `.txt`, `.csv`, `.json` and the summary `.md`, which now ends with the migration times
- the measurement: `tp-bench-<context>-<date>.json` and `.md`
- the estimate: `tp-estimate-<context>-<date>.md`, its `.csv` files and the `.xlsx` if it was made

The test data is deleted with the namespace.
