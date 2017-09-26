#lang scribble/manual
@(require scribble/core)
@(require scribble-math)

@title{HAMT: An Efficient Persistent Map}
@; Think of snappy title

@(define (capitalize-first-letter str)
  (regexp-replace #rx"^." str string-upcase))

@; See how I used unquote-splicing here like a Racket pro
@(define (kris . comment)
  (apply string-append `("(Kris: " ,@comment ")")))

@(define (tom . comment)
  (apply string-append `("(Kris: " ,@comment ")")))

@; This is a total hack. I don't know how to get Scribble to allow me 
@; manipulate the width of rendered images. Might have to pay with
@; scribble/html?

@; Narrow
@(define (cimgn path)
   (centered (image path #:scale .3)))

@; Wide
@(define (cimgw path)
   (centered (image path #:scale .5)))

@link["https://thomas.gilray.org/"]{Thomas Gilray} (@link["https://twitter.com/tomgilray"]|{@tomgilray}| )
@(linebreak)
@link["http://kmicinski.com"]{Kristopher Micinski} (@link["https://twitter.com/krismicinski"]|{@krismicinski}|)

@; @table-of-contents

@section{Introduction}

@section{Motivation: Persistent Maps}

Let's say we wanted to implement a phonebook using a mutable map:

@(cimgn "images/map1.png")

When a friend's number changes, we would make a corresponding change
to the map:

@(cimgn "images/map2.png")

Now imagine I want to keep a history of my phonebook. What I really
want is a time slider that allows me to see the state of the phonebook
at any point in time:

@(cimgw "images/maptime.png")

The problem with a mutable map is that I invalidate older copies of
the phonebook when I update keys that exist in the phonebook at
earlier times. I need a data structure that supports:

@itemlist[
 @item{@tt{insert(key,value)}, which gives me back a new map
  containing all the same pairs as the old one, except for the newly
  inserted pair, or update to existing pair. That is, I want a
  functional insert operation that consumes and produces immutable
  maps.}

@item{@tt{lookup(map,key)}, that looks up a record in the map. This
  should run in near-constant time.}

 @item{@tt{delete(map,key)}, that removes a record from the map. Just
 like @tt{insert}, this should both consume and produce a functional
 map.}
]

Note that we could technically obtain a persistent map by simply
cloning a mutable map each time we perform a change:

@(cimgn "images/copymap.png")

But this uses both linear time and linear space, which falls far short
of what we'd like. As we'll see, the key to a more efficient data
structure is sharing.

@; Really need this to be a subsection? Or blow away this header?
@subsection{Towards a solution: association lists}

@kris{This section still seems weird. I.e., I say we want to move to a
more persistent data strucutre. But our lits don't do that! So it
seems kind of dumb like a bait and swtich. What do you think we should
do about that?}

To get towards a more persistent data structure, we can switch to using
association lists.  Association lists are linked lists made up of
key-value pairs. To perform @tt{lookup(map,k)}, we walk down the links
of @tt{map} until we find a link with the corresponding key.

To perform @tt{insert(map,k,v)}, we first traverse each link of
@tt{map} (as in @tt{lookup}) to ensure that no pair for @tt{key}
exists. If it does not, we append a link which contains @tt{k,v} to
the end of the list, sharing the prefix:

@(cimgn "images/assoclist2.png")

If @tt{key} exists in @tt{map}, we need to modify our approach
slightly, so that we allocate a new cell for @tt{k,v} and splice it
into the list in the appropriate location (while leaving @tt{map}
alone).

This means our lookup times can be in @($ "O(n)"), but then so are our
insert, remove and space overheads. But in the case that no key
exists, we exploit @emph{sharing}, so that insertions into a list
where no key previously exists reuses most of the links of the
previous list, only adding a single new link to hold the incremental
change to the map.

@tabular[#:style 'boxed
         #:sep @hspace[1]
 (list (list @bold{Operation} @bold{Runtime} @bold{Space overhead})
       (list @tt{insert}  ($ "O(n)") ($ "O(n)"))
       (list @tt{lookup}  ($ "O(n)") "-")
       (list @tt{remove}  ($ "O(n)") ($ "O(n)"))
       )]

In practice, association lists are not a particularly efficient data
structure, but we'll see that their implementation will be one
component that will help get us towards implementing HAMT. To obtain
HAMT, we'll use several tiers of hashmaps, along with sharing between
those tiers. At the final tier we'll use an association list, as we
would in a regular hashmap, to account for the possibility of hash
collisions.

@subsection[#:tag "linkedlist"]{Implementing association lists}

Let's see how we implement association lists. First,
we're going to represent each individual link as a key,
value, and pointer to next node. We want the key and value
to be of arbitrary types, so we're going to use C++
templates. Let's start by stubbing out the class definition:

@codeblock[#:line-numbers 1]|{
template <typename K, typename V>
class LL
{
    typedef LL<K,V> LLtype;
    
public:
    const K* const k;
    const V* const v;
    const LLtype* const next;

    LL<K,V>(const K* k, const V* v, const LLtype* next)
        : k(k), v(v), next(next)
    { }

    const V* find(const K* const k) const;

    const LLtype* insert(const K* const k, const V* const v) const;

    const LLtype* remove(const K* const k) const;
}
}|

Note on lines 7-9 that all of our pointer types have @tt{const}
qualifiers, meaning we won't be able to modify the data
being pointed at, or the pointers to the keys and values
themselves. This is exactly the behavior we want for our
association list; otherwise, sharing portions of old association
lists would be impossible as modifying them could modify all
maps that had previously been derived from them. Our constructor
therefore initializes fields and nothing else.

A find or lookup algorithm is defined as a straightforward traversal
that returns a @tt{const V*} or null pointer.

@codeblock[#:line-numbers 1]|{
    const V* find(const K* const k) const
    {
        if (*(this->k) == *k)
            return v;
        else if (next)
            return next->find(k);
        else
            return 0;
    }
}|

The insert algorithm descends the association list checking for a matching key (line 3). If it matches,
we rebuilt the current node using an updated value @tt{LLtype(this->k, v, next)} (line 4) and @emph{placement new}
syntax @tt{new ((T*)ptr) T(...)} which constructs a value at an existing location---in this case, new memory obtained
from the Boehm garbage collector.

@codeblock[#:line-numbers 1]|{
    const LLtype* insert(const K* const k, const V* const v) const
    {
        if (*(this->k) == *k)
            return new ((LLtype*)GC_MALLOC(sizeof(LLtype)))
                         LLtype(this->k, v, next);
        else if (next)
            return new ((LLtype*)GC_MALLOC(sizeof(LLtype)))
                       LLtype(this->k, this->v, next->insert(k, v));
        else
        {
            const LLtype* const link1 =
              new ((LLtype*)GC_MALLOC(sizeof(LLtype))) LLtype(this->k, this->v, 0);
            const LLtype* const link0 =
              new ((LLtype*)GC_MALLOC(sizeof(LLtype))) LLtype(k, v, link1);
            return link0;                
        }
    }
}|

In the case where the current link doesn't match but has a non-null tail, the current node is rebuilt to refer to whatever
@tt{LLtype} pointer is returned from a recursive insert (line 6). If the end of the list is reached with no key found,
we may insert the new element on the front or back of the list. In this case we show the latter for simplicity.

@section{Next: Trees and Tries}

A standard data structure in any programmer's arsenal is the sorted tree.
Trees give you nice logarithmic runtime costs when balanced.

@(cimgn "images/tree.png")

The problem with trees is that in the worse case they give
lookup performance no better than a list:

@(cimgn "images/badtree.png")

This happens when elements are inserted in order. A number
of techniques exist to avoid this worst-case behavior. For
example,
@link["https://en.wikipedia.org/wiki/Red%E2%80%93black_tree"]{
 Red-Black trees} automatically rebalance upon each @tt{
 insert} operation. Unfortunately, this requires mutability so
 an existing tree may be rewired into a more balanced version of itself.

A way of constructing a balanced binary tree probabilistically
would be to randomize elements before inserting them. This would
avoid the worst-case behavior of inserting elements in sorted order.
A way to effect this kind of probabalistic balancing, but without changing
insertion order, would be to hash each key and insert into
the tree based on its hash. So long as we only care to match keys
exactly and do not need to exploit an ordering on keys, this is a
sound alternative. Each node in the tree is now a:

@itemlist[
 @item{A pointer to the left and right subtrees}
 @item{A hash of the key for that cell, and}
 @item{A pointer to a linked list of key-value pairs}
]

The reason for the last item is that hashes have the
possibility of @emph{collision}: two values can hash to the
same thing. If we use a sufficiently large hash, and a good
hash function, this will happen only rarely. Here's an example of
what our hash-tree looks like, with the linked lists
highlighted in green:

@(cimgn "images/hashtree.png")

@subsection{Worst case behavior}

Note that we have done nothing to improve the worst-case
behavior of our binary tree. We could still end up in this
scenario (note that the linked lists are elided):

@(cimgn "images/worsttree.png")

This means that the complexity of operations on our tree is
@emph{still} @($ "O(n)"). Let's tackle that next.

@subsection{From sorted trees to tries (prefix trees)}

Turning our sorted tree into a hash-tree doesn't buy us any
performance improvement, but it helps us make our way
towards exploiting some of the unique properties of the
hash-tree.

Hashes naturally form a common-prefix ordering:

@(cimgn "images/prefixnums.png")

Each element in the sequence is a suffix of the element
before it. We can also represent the elements elements of a
binary tree:

@(cimgn "images/numbertrie.png")

However, note that if we force our tree to be a trie (pronounced "try"),
it is @emph{not} possible to represent the worst-case
configuration shown above: @tt{0x00000001} is not a prefix
of @tt{0x00000002}. 

@;I am not understanding this point, or generally the point about the worst-case being O(n). It is for our
@;final HAMT design as well. I think good stochastic complexity is the best we can do and is just fine... 


@subsubsection{Exploiting the Trie}

If we force our trees to be tries, and assuming we use a
64-bit hash, we can reduce the maximum depth of our trees
from @($ "O(n)") to just 64! The way we do this is to represent our
key-value pairs using a trie, where each node represents a
@emph{partial} hash, a prefix. Note that--for now--we have left off
the value component of the key-value pairs and are simply
drawing the hashes. We will get back to that shortly.
@; This text needs major fixing since it feels rough.

@(cimgw "images/binarytrie.png")

Notice that each child node is arranged such that it is a
prefix of its parent. Our trie can be viewed as a decision
tree, at each step answering the question, "is the next bit zero or one?"
Keep in mind that, at leaf nodes, we will still have
to keep a key-value association list. It remains possible for us
to have (improbable) hash collisions.


@subsection{A few optimizations}

Our trie now avoids the worst-case behavior we observed with
a sorted binary tree, which appears better in theory, but
@; better in theory? How so? Ordering? Some of your thinking on trees vs tries isn't making sense to me I think.
has a few undesirable traits in practice:

@itemlist[
 @item{A maximum depth of 64 is still quite a large tree to traverse in the worst-case}
 @item{In the case that the map is relatively sparse--i.e.,
  that it doesn't contain many key-value pairs, we are still
  required to traverse all the way down to the leaf just to lookup one key-value pair.}
 ]

@subsubsection{Reducing the Height}

To solve the first problem, we can simply switch from a
binary tree to an n-ary tree: in our case, we're going to
hold 64 "buckets" at each node, rather than 2. By doing
this, we lower the maximum depth of our tree (to 10-11).
Instead of each node deciding whether a bit will be a 0 or a
1, each node will decide whether the next 6 bits of the hash
are @tt{0x00} to @tt{0x3F}:

@(cimgn "images/buckets.png")

Now our trie will have a structure like this:

@(cimgn "images/fullbuckets.png")


@subsubsection[#:tag "lazy"]{Build It Lazily}

@; Lazy seems like a heavyweight idea to employ here, can't we just make this one subsection
@; and say we only extend the trie as necessary. I wouldn't call this "laziness" at all...
It turns out that most of the time, our trie won't really
need to be of depth ten. In fact, in the following scenario,
we'd waste a lot of time traversing pointers:

@(cimgn "images/wasted.png")

This is because each key occupies a different bucket for the
top level node. In fact, we could just use a
configuration like the following instead:

@(cimgn "images/lesswasted.png")

What we ultimately want is a data structure that stores the
key-value pair as close to the top as possible until it has
to keep things separate.

To do that, the nodes in our trie will either hold 64
buckets for child nodes, or will hold an association list of
key-value pairs. Remember, they can't possibly hold one @; they can possibly and do in our final implementation...
unique key-value pair because hash collisions are always
possible. This optimizes our trie so that in cases that we
don't @emph{need} additional depth, we won't be using it.
Additionally, assuming we're using a suitable hash function,
we should get relatively good dispersion between buckets.
This means that--probabilistically--we'll be holding most
things closer to the top until the map is holding a lot of
key-value pairs.

@; I really think the better way to put this is that we're using a union
@; to make our representation more compact... nothing is happening "lazily" in the normal sense
One way to think about this is that we will build the nodes
in our trie lazily, only using as many bits of the hash as
we need. If we can differentiate all of the hashes of our
key-value pairs using their first six bits, we will only
have one "layer" of the trie that we need to traverse untilxs
we reach the data we want to access.

If we lay out our trie in this manner, we need to be careful
about how insertion happens. For example, consider a trie
which stores a record for José near the top. Let's assume
the string "José" hashes to @tt{0xFC0..} (we will only need
the first 12 digits for this example). José's record will be
stored in the key-value pair association list for the @tt{
 0x3F} bucket of the first node. Now consider what happens
when we want to insert a key-value pair for Sam, which (for
the purposes of illustration) we will assume hashes to @tt{
 0xFFF}. Because the first six binary digits of the hahes for
José and Sam both hash to @tt{0x3F}, we will need to split
that bucket into @emph{another} bucket, holding another 64
values.

Here's an illustration of how insert works given this
configuration:

@(cimgw "images/split.png")


@subsubsection[#:tag "compress"]{Reducing the Memory}

When the trie is relatively sparse, assigning 64 buckets to
each node is inefficient in terms of both space (occupied by
each node) and time (spent copying memory to allocate new
nodes). It turns out that we can use a low-level trick
to compress sparse nodes in the trie.

The trick is to use a bitmap to represent which
child hashes are actually stored in a node. Instead of each
node holding 64 buckets, a node will hold a single 64-bit
value, @tt{bitmap}, along with a variable-length buffer of
pointers to child nodes, @tt{data}. The node will be laid out
so that, if position i in @tt{bitmap} is a 1
(i.e., @tt{bitmap & (0x01 << i) > 0}),
@; this expression was previously wrong; it wouldn't equal 1 if it was 2^n
it will represent the fact that the
bucket i is occupied. We will lay out @tt{data} such that
its length is equal to the number of 1s in the
binary representation of @tt{bitmap}. The ith index into
@tt{data} will be regarded as the bucket occupied by the
(i+1)th occurrence of 1 in the binary representation of @tt{
 bitmap}.

This is tricky, so here's a picture:

@(cimgw "images/oldvsnew.png")

The old representation of a trie node is shown on the left.
The new, more efficient, representation is shown on the
right. In the old representation we can see 64 buckets, with
José occupying the first bucket at position @tt{0x00}, and
Sam occupying the last at position @tt{0x3F}. Between them
is 62 null pointers to pieces of hashes which have not yet
been inserted into the trie.

In our new representation we see the bitmap and a @tt{data}
array of two elements. Because José's hash occupies position
@tt{0x00} in the old representation, the 0th bit of @tt{
 bitmap} will be set to 1. Similarly, because Sam's hash
occupied position @tt{0x3F} in the old representation, the
63th bit of @tt{bitmap} will be set.
@; You can't have a 0th bit and 64th bit both in a 64 bit
@; value! Either counting starts at 0 or at 1...

To access Sam's record, we lookup position 63 in @tt{bitmap}
and check to see whether it is set to 1. If not, it will
signify that no record exists for Sam in this node. Assuming
it is, we then count the number of 1s @emph{below} position
63 in the bitmap. This operation is called @tt{popcount}
(short for "population count," which counts the number of 1s
in a machine word), and built into many modern instruction
sets, so that it executes quite efficiently. We then use
@tt{popcount} of the part of @tt{bitmap} below the 63th bit
to index into @tt{data}.

By doing this, we reduce the amount of space stored for each
node from 64 to @tt{popcount(bitmap)}. In practice, this
means that we get good performance when the trie is sparse,
and when the trie is dense (i.e., most nodes hold close to
64 child elements) the performance is hardly worse than an
implementation without compression.

@; Do we want to talk about storing the bit map alongside the key for cache coherence. 



@section{Implementing HAMT}

The combination of these techniques gives us the Hash
Array-Mapped Trie (HAMT). Now we'll step through an
efficient implementation of HAMT that uses these concepts.

@subsection{The node representation}

Nodes are represented by a templated C++ class @tt{KV<K,V,d>}, where:

@itemlist[
 @item{@tt{K} is the template parameter for the key's type}
 @item{@tt{V} is the value's type}
 @item{@tt{d} is the depth of the node being represented}
 ]

The last parameter deserves some explanation. Imagine how
nodes are to be implemented. At each depth in the HAMT, a node
handles a 6-bit piece of a 64-bit hash. In our
implementation, the root node (which we'll implement soon as
a class called @tt{hamt}) will hold 4 of those bits, while
the 60 remaining bits will be handled by sub-tries whose
maximum depth is 10. After depth 10, all values which would
share the same bucket also share the same hash, and so the trie
devolves into an association list.

To do its work, each inner node in HAMT must know which
6-bit piece of the hash its working on. We could handle this by
computing this value as we traverse down through the trie nodes,
gradually moving from the first four bits (for the
top level node, which holds four bits), to the next six
bits, to the next six bits, etc. However, instead, we're
going to use template metaprogramming to generate a
template-specialized version of the node class for each
depth from 1 to 10. This means that the C++ compiler will
generate @tt{KV<K,V,0>} through @tt{KV<K,V,9>} for us using
our template, and we will manually specialize @tt{KV<K,V,10>}
to be an implementation that may use an association list.
In essence, we have traded various dynamic checks that would
otherwise happen at @emph{runtime} for a specialization of the
code at @emph{compile time}.

Here's the C++ code representation for our inner nodes:

@codeblock[#:line-numbers 1]|{
// A key-value pair; this is both one row in Bagwell's underlying AMT
// or a buffer of such KV rows in an internal node of the data structure
template <typename K, typename V, unsigned d>
class KV
{
    typedef KV<K,V,d> KVtype;
    typedef KV<K,V,d+1> KVnext;

public:
    // We use two unions and the following cheap tagging scheme:
    // when the lowest bit of Key k is 0, it's a key and a K*,V* pair (key and value),
    // when the lowest bit of Key k is 1, it's either a bm (bitmap) in the top 63 bits with a
    // KV<K,V,d+1>* v inner node pointer when d is less than 9 or it's just a 1 and a pointer to a
    // LL<K,V>* for collisions
    union Key
    {
        const u64 bm;
        const K* const key;

        Key(const K* const key) : key(key) { }
        Key(const u64 bm) : bm(bm) { }
    } k;

    union Val
    {
        const KVnext* const node;
        const V* const val;

        Val(const KVnext* const node) : node(node) { }
        Val(const V* const val) : val(val) { }
    } v;
    // ...
}
}|

We use C++ unions to allow this node to either be a
key-value pair, or an inner node, to implement the trick in
section @secref["lazy"]. There are two possibilities for this node:

@itemlist[
 @item{It is a single key-value pair. In this case, we will
  simply use the @tt{K*}, @tt{V*} pair. The bits of k will
  encode a pointer to the key object, which we can use on subsequent
  lookups. The reason we can do this is that pointers to keys
  will always be aligned, and so the lowest bit will never be
  zero! This allows us to use that lowest bit to tag these unions;
  when it is a zero, @tt{k} is a key and @tt{v} is a stored value.
  }

 @item{There is more than one matching key for this prefix.
  In this case, we set the lowest bit of @tt{k} to 1. The rest of @tt{k} will
  be a 63-bit bitmap, and @tt{v} will point to a compressed buffer, @tt{data},
  of keys and values as discussed in section @secref["compress"].
  }
 ]

The lowest level of our HAMT will either store keys and values or,
where collisions exist, the value 1 for @tt{k} and a pointer to an association list
for @tt{v}. This uses the linked list we implemented in section @secref["linkedlist"]:

@codeblock[#:line-numbers 1]|{
// A template-specialized version of KV<K,V,d> for the lowest depth of inner nodes, d==10
// After this we have exhausted our 64 bit hash (4 bits used by the root and 6*10 bits used by inner nodes)
template <typename K, typename V>
class KV<K,V,10>
{
    typedef LL<K,V> LLtype;
    typedef KV<K,V,10> KVbottom;

public:
    // We use two unions and the following cheap tagging scheme:
    // when the lowest bit of Key k is 0, it's a key and a K*,V* pair (key and value),
    // when the lowest bit of Key k is 1, it's either a bm (bitmap) in the top 63 bits with a
    // KVnext* v inner node pointer when d is less than 9 or it's just a 1 and a pointer to a
    // LL<K,V>* for collisions (In this case we use LL<K,V>*)
    union Key
    {
        const u64 bm;
        const K* const key;

        Key(const K* const key) : key(key) { }
        Key(const u64 bm) : bm(bm) { }
    } k;

    union Val
    {
        const LLtype* const list;
        const V* const val;

        Val(const LLtype* const ll) : list(ll) { }
        Val(const V* const val) : val(val) { }
    } v;
    // ...
}
}|

The toplevel @tt{hamt} data structure will hold the first
four bits of the hash, and each element of @tt{data} will
hold either a key-value pair or an inner node:

@codeblock[#:line-numbers 1]|{
// A simple hash-array-mapped trie implementation (Bagwell 2001)
// Garbage collected, persistent/immutable hashmaps
template<typename K, typename V>
class hamt
{
    typedef KV<K,V,0> KVtop;

private:
    // We use up to 4 bits of the hash for the root, then the
    // other 10*6bits are used for inner nodes up to 10 deep
    KVtop data[16];
    u64 count;

public:
    hamt<K,V>()
        : data{}, count(0)
    {}
    // ...
}
}|


@subsection{Finding a key-value pair in HAMT}

To find a key-value pair in HAMT, we start at the topmost
node and check the first four bits to find which top-level
bucket the value is stored in:

@codeblock[#:line-numbers 1]|{
const V* get(const K* const key) const
{
    // type K must support a method u64 hash() const;
    const u64 h = key->hash();
    const u64 hpiece = (h & 0xf);

    if (this->data[hpiece].k.bm == 0)
        // It's a zero, return null for failure
        return 0;
    else if ((this->data[hpiece].k.bm & 1) == 0)
    {
        // It's a key/value pair, check for equality
        if (*(this->data[hpiece].k.key) == *key)
        {
            return this->data[hpiece].v.val;
        }
        else
            return 0;
    }
    else
        // It's an inner node
        return KVtop::inner_find(this->data[hpiece], h >> 4, key);
}                              
}|

We use the first four bits of the hash to calculate which
index of @tt{data} to look at next. The lowest bit of the
corresponding key for @tt{data[hpiece]} is then used to
check if that bucket contains a key-value pair directly--in
which case the key is directly checked and the value
returned--or to see if @tt{data[hpiece]} contains an inner
node, in which case we delegate to that node's @tt{
 inner_find}. Note that @tt{inner_find} is called with the
hash shifted by four.


@subsubsection{Lookup from an inner node}

Internal nodes look at six-bit pieces of the hash from
the 5th bit to the 64th bit in the hash. By convention, we
assume that @tt{inner_find} will only look at the bottom six
bits of the hash, and that it will always be called in such
a way that the bits have been shifted appropriately:


@codeblock[#:line-numbers 1]|{
// This is the find algorithm for internal nodes
// Given a KV row pointing to an inner node, returns the V* for a given h and key pair or 0 if none exists
static const V* inner_find(const KVtype& kv, const u64 h, const K* const key)
{
    const u64 hpiece = (h & 0x3f) % 63;

    // bm is the bitmap indicating which elements are actually stored
    // count is how many KV elements this inner node stores (popcount of bm)
    // i is hpiece's index; i.e., how many KV elements *preceed* index hpiece
    const KVnext* const data = kv.v.node;
    const u64 bm = kv.k.bm >> 1;

    const bool exists = bm & (1UL << hpiece);
    if (exists)
    {
        const u32 i = __builtin_popcountll((bm << 1) << (63 - hpiece));
        if ((data[i].k.bm & 1) == 0)
        {
            if (*(data[i].k.key) == *key)
                return data[i].v.val;
            else
                return 0;
        }
        else
            return KVnext::inner_find(data[i], h >> 6, key);
    }
    else
        return 0;
}
}|

Note that we right-shift the bitmap by one, because the
lowest bit will be set to 1 based on the tagging
scheme discussed above. We use the @tt{__builtin_popcountll}
function to calculate @tt{popcount} in an efficient way. The
compiler will then either generate architecture-specific
instructions, or (if compiling for an architecture where
@tt{popcount} has not been implement) an
@link["https://arxiv.org/pdf/1611.07612.pdf"]{optimized set of  assembly instructions}
to do so. We then use the result of
@tt{popcount} to look up the corresponding index in @tt{data},
and perform the lookup for the key-value pair or
again delegate to @tt{inner_find}.


@subsection{Inserting Into HAMT}

Inserting into a HAMT involves many of the same operations as
searching for a key-value pair. First, @tt{popcount} is used to determine
the overall length of the compressed buffer @tt{data}, and the index @tt{i}
of the @tt{KVnext} for the prefix that includes the next six-bit piece @tt{hpiece}.
Note that because we need the lowest bit of @tt{k} for tagging, we take each hash
piece modulo 63, conflating the numbers 0 and 64. Assuming our hash function is
decent, this shouldn't impact performance in practice.

@codeblock[#:line-numbers 1]|{
    // Inserts an h, k, v into an existing KV and returns a fresh KV for extended hash
    static const KVtype insert_inner(const KVtype& kv, const u64 h, const K* const key, const V* const val, u64* const cptr)
    {
        // data is a pointer to the inner node at kv.v
        // bm is the bitmap indicating which elements are actually stored
        // count is how many KV elements this inner node stores (popcount of bm)
        // i is hpiece's index; i.e., how many KV elements *preceed* index hpiece
        const KVnext* const data = kv.v.node;
        const u64 bm = kv.k.bm >> 1;        
        const u32 hpiece = (h & 0x3f) % 63;
        const u32 count = __builtin_popcountll(bm);
        const u32 i = __builtin_popcountll((bm << 1) << (63 - hpiece));

        const bool exists = bm & (1UL << hpiece);
        if (exists)
        {
            // Check to see what kind of KV pair this is by checking the lowest bit of k
            //   0 -> it's an actual K*,V* pair
            //   1 -> it's either another inner node (KV*) or a linked list (LL<K,V>*) depending on d+1
            if ((data[i].k.bm & 1) == 0)
            {
                // Does the K* match exactly?
                if (*(data[i].k.key) == *key)
                {
                    // it already exists; replace the value  
                    const KVnext* const node = KVnext::update_node(data, count, i, KVnext(key,val));
                    return KVtype(kv.k.bm, node);
                }                    
                else
                {
                    // Merge them into a new inner node
                    (*cptr)++;
                    const KVnext childkv = KVnext::new_inner_node(
                        // Passes in the first triple of h,k,v, then the second
                        // When shifting the just-recomputed hash right, this formula is computed at compile time
                        // This also means a warning on the d=9 template instantiation, so we do %64 as d=10
                        // does not care in any case as it's definitely a LL*.
                        (data[i].k.key->hash() >> ((6*(d+1)+4)) % 64), data[i].k.key, data[i].v.val,
                        h >> 6, key, val);
                    const KVnext* const node = KVnext::update_node(data, count, i, childkv);
                    return KVtype(kv.k.bm, node);
                }
            }
            else //if ((data[i].k & 1) == 1)
            {
                // an inner node is already here; recursively do an insert and replace it
                const KVnext childkv = KVnext::insert_inner(data[i], h >> 6, key, val, cptr);
                const KVnext* const node = KVnext::update_node(data, count, i, childkv);
                return KVtype(kv.k.bm, node);
            }
        }
    }
}|

If the @tt{KVnext} for this @tt{hpiece} exists in the compressed buffer @tt{data},
control takes the first branch of the conditional @tt{if (exists)}, otherwise it takes
the second. When the the KV doesn't exist, a new inner node is allocated with one
additional index for the new key and value. A pointer to a counter value @tt{cptr} is incremented
to track that the number of keys in the map has increased. A single KV of @tt{KVtype}, as opposed
to @tt{KVnext}, is returned that points to this larger internal node and has an updated bitmap.

In the case that the KV at hpiece exists, it is either a key and value, or another internal node.
If it is a key and value where the key matches exactly, the value can be updated in
a copy of the node that is returned. Functionally updating a single index of an internal node
is handled by a helper method @tt{update_node}:

@codeblock[#:line-numbers 1]|{
    static const KVtype* update_node(const KVtype* old, const u32 count, const u32 i, const KVtype& kv)
    {
        KVtype* copy = (KVtype*)GC_MALLOC(count*sizeof(KVtype));
        std::memcpy(copy, old, count*sizeof(KV));
        new (copy+i) KVtype(kv);
        return copy;
    }
}|

If the key matches in its hash only, the two keys
are merged into a new internal node using a helper function @tt{new_inner_node}:

 @codeblock[#:line-numbers 1]|{
    // Helper returns a fresh inner node for two merged h, k, v triples
    static const KVtype new_inner_node(const u64 h0, const K* const k0, const V* const v0,
                                       const u64 h1, const K* const k1, const V* const v1)
    {
        // Take the lowest 6 bits modulo 63 
        const u32 h0piece = (h0 & 0x3f) % 63;
        const u32 h1piece = (h1 & 0x3f) % 63;
        
        if (h0piece == h1piece)
        {
            // Create a new node to merge them at d+1
            const KVnext childkv = KVnext::new_inner_node(h0 >> 6, k0, v0, h1 >> 6, k1, v1);
            KVnext* const node = (KVnext*)GC_MALLOC(sizeof(KVnext));
            new (node+0) KVnext(childkv);
             
            // Return a new kv; bitmap indicates h0piece, the shared child inner node
            return KVtype(((1UL << h0piece) << 1) \| 1, node);                
        }
        else
        {
            // The two key/value pairs exist at different buckets at this d
            // allocate them in proper order 
            KVnext* const node = (KVnext*)GC_MALLOC(2*sizeof(KVnext));
            if (h1piece < h0piece)
            {
                new (node+0) KVnext(k1,v1);
                new (node+1) KVnext(k0,v0);
            }
            else
            {
                new (node+0) KVnext(k0,v0);
                new (node+1) KVnext(k1,v1);
            }
            

            // Return a new kv; bitmap indicates both h0piece and h1piece
            return KVtype((((1UL << h0piece) \| (1UL << h1piece)) << 1) \| 1, node);
        }
    }
}|

Note that in the case where the two keys continue to match in the next chunk of their hash,
the helper @tt{new_inner_node} makes a recusive call to itself.




