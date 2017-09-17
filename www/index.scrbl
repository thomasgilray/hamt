#lang scribble/manual
@(require scribble/core)
@(require scribble-math)

@title{HAMT: An Efficient Persistent Map}
@; Think of snappy title

@(define (capitalize-first-letter str)
  (regexp-replace #rx"^." str string-upcase))

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

Let's first illustrate why we might want a persistent map.
Mutable maps, typically implemented as hash tables,
naturally appear in many applications throughout computing.
For example, we might imagine implementing a phone book as a
mutable map:

@(cimgn "images/map1.png")

This allows us to quickly look up phone numbers for all of
the friends we care about, even if we have thousands of
friends in our phonebook. When someone's number changes, we
would make a corresponding change to the map:

@(cimgn "images/map2.png")

This works for a single person, but imagine that I'm a city
recordkeeper. Along with knowing each person's phone number
today, I also want to be able to look up what their number
was at a given time. What I really want is a long stream of
these phonebooks, and a time slider to tell me who had what
number on a given day:

@(cimgw "images/maptime.png")

I need my map implementation to support a special type of
@tt{insert} operation, which returns a new map that contains
all of the same elements as the old one, except for the new
element I'm inserting.


@section{Towards a solution}

The first thing we might try is to simply copy the mutable
hash table and change the relevant element upon an
insertion. Now @tt{insert} looks like this:

@(cimgn "images/copymap.png")

But there are major problems with this. Let's think about
the runtime and space complexity of the two relevant
operations we want to perform, @tt{insert(k,v)} and @tt{
 lookup(k)}:
@tabular[#:style 'boxed
         #:sep @hspace[1]
 (list (list @bold{Operation} @bold{Runtime} @bold{Space overhead})
       (list @tt{insert}  ($ "O(n)") ($ "O(n)"))
       (list @tt{lookup}  ($ "O(1)") "-"))
       ]

Insertion runtime complexity is linear in the number of
entries in the map because to insert an item, we first have
to copy the entire table into a newly allocated chunk of
memory. This also incurs space overhead linear in the size
of the table.

This solution would work well if we had to make copies of
the map only occasionally, but if we were doing so
routinely, our system would be both relatively slow and take
up a lot of space. If the phonebook grew relatively large,
and we had frequent edits, we might quickly end up
exhausting memory.

We can reduce the runtime and space overhead to @${O(1)} by
switching our implementation to using association lists.
Association ls are linked lists made up of key-value
pairs. To lookup an element in an association list, we
simply walk down the list until we find an element with the
corresponding key and return its value. Insertion is simple,
we prepend a new key-value pair to the list:

@(cimgn "images/assoclist.png")

The association list uses sharing to achieve both constant
time and space complexity for insertion. But to lookup a
value, we potentially need to go far down into the
association list. So our table now looks like:

@tabular[#:style 'boxed
         #:sep @hspace[1]
 (list (list @bold{Operation} @bold{Runtime} @bold{Space overhead})
       (list @tt{insert}  ($ "O(1)") ($ "O(1)"))
       (list @tt{lookup}  ($ "O(n)") "-"))
       ]

This is good if we do frequent copies but infrequent
lookups. Still, we'll see that an association list is a
useful component for building a more efficient persistent
map, so let's start by implementing it.

@subsection[#:tag "linkedlist"]{Implementing association lists}

Let's see how we might implement association lists. First,
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

    const LLtype* insert(const K* const k, const V* const v, u64* const cptr) const;

    const LLtype* remove(const K* const k, u64* const cptr) const;
}
}|

Note on lines 7-9 that all of our pointers have constant
specifiers, meaning we won't be able to change the data
being pointed at, or the pointers to the keys and values
themselves. This is exactly the behavior we want for our
association list, imagine how confusing it would be if we
built a subsequent association list, and then someone
changed one of the values out from under us!.

This section not yet finished...

@section{Next: Trees and Tries}

One of the most standard data structures in the functional
programmer's arsenal is the sorted tree. Trees give you nice
logarithmic runtime and offer efficient persistence by
sharing nodes:

@(cimgn "images/tree.png")

The problem with trees is that in the worse case they give
lookup performance no better than a list:

@(cimgn "images/badtree.png")

This happens when elements are inserted in order. A number
of techniques exist to avoid this worst-case behavior. For
example,
@link["https://en.wikipedia.org/wiki/Red%E2%80%93black_tree"]{
 Red-Black trees} automatically rebalance upon each @tt{
 insert} operation.

One way of constructing a constructing a balanced binary
tree probabilistically (most of the time) is to randomize
the elements before inserting them. This avoids the
worst-case behavior of inserting elements in sorted order.
One way to do this would be to hash each key and insert into
the tree based on that hash. This won't immediately buy us a
performance improvement, but it will get us closer to the
core design of HAMT. Each node in the tree is now a:

@itemlist[
 @item{A pointer to the left and right subtrees}
 @item{A hash of the key for that cell}
 @item{A pointer to a linked list of key-value pairs}
]

The reason for the last item is that hashes have the
possibility of @emph{collision}: two values can hash to the
same thing. If we use a sufficiently large hash, and a good
hash function, this will happen rarely. Here's an example of
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

@subsection{From trees to tries}

Turning our sorted tree into a hash-tree doesn't buy us any
performance improvement, but it helps us make our way
towards exploiting some of the unique properties of the
hash-tree.

Hashes form a very natural prefix-ordering:

@(cimgn "images/prefixnums.png")

Each element in the sequence is a suffix of the element
before it. We can also represent the elements elements of a
binary tree:

@(cimgn "images/numbertrie.png")

However, note that if we force our tree to be a trie, it is
@emph{not} possible to represent the worst-case
configuration shown above: @tt{0x00000001} is not a prefix
of @tt{0x00000002}.

@subsubsection{Exploiting the Trie}

If we force our trees to be tries, and assuming we use a
64-bit hash, we can reduce the maximum size of our trees
from @($ "O(n)") to 64! The way we do it is to represent our
key-value pairs using a trie, where each node represents a
@emph{partial} hash. Note that--for now--we have left off
the value component of the key-value pairs and are simply
drawing the hashes, we will get back to that shortly.
@; This text needs major fixing since it feels rough.

@(cimgw "images/binarytrie.png")

Notice that each child node is arranged such that it is a
prefix of its parent. Our trie can be viewed as a decision
tree, answering the question, "is the next bit zero or one?"
Because we only have a 64-bit hash, our trie will have depth
64! Keep in mind that at the leaf nodes, we will still have
to keep a key-value association list, because it's always
possible to have hash collisions. However, the likelihood of
that happening with a good hash function is relatively low.

@subsection{A few optimizations}

Our trie now avoids the worst-case behavior we observed with
a sorted binary tree, which appears better in theory, but
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
this, we'll lower the maximum depth of our tree to be 10.
Instead of each node deciding whether a bit will be a 0 or a
1, each node will decide whether the next 6 bits of the hash
are @tt{0x00} to @tt{0x3F}:

@(cimgn "images/buckets.png")

Now our trie will have a structure like this:

@(cimgn "images/fullbuckets.png")

@subsubsection[#:tag "lazy"]{Build It Lazily}

It turns out that most of the time, our trie won't really
need to be of depth ten. In fact, in the following scenario,
we'd waste a lot of time traversing pointers:

@(cimgn "images/wasted.png")

This is because each key occupies a different bucket for the
top level node. In fact, we could instead just a
configuration like the following:

@(cimgn "images/lesswasted.png")

What we ultimately want is a data structure that stores the
key-value pair as close to the top as possible until it has
to keep things separate.

To do that, the nodes in our trie will either hold 64
buckets of child nodes, or will hold an association list of
key-value pairs. Remember, they can't possibly hold one
unique key-value pair because hash collisions are always
possible. This optimizes our trie so that in cases that we
don't @emph{need} additional depth, we won't be using it.
Additionally, assuming we're using a suitable hash function,
we should get relatively good dispersion between buckets.
This means that--probabilistically--we'll be holding most
things closer to the top until the map is holding a lot of
key-value pairs.

One way to think about this is that we will build the nodes
in our trie lazily, only using as many bits of the hash as
we need. If we can differentiate all of the hashes of our
key-value pairs using their first six bits, we will only
have one "layer" of the trie that we need to traverse until
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
nodes). It turns out that we can use a representation trick
to compress sparse nodes in the trie.

The key to our trick is to use a bitmap to represent which
child hashes are being stored by a node. Instead of each
node holding 64 buckets, a node will hold a single 64-bit
value, @tt{bitmap}, along with an array of pointers to child
nodes, @tt{data}. The node will be laid out so that, if
position i in @tt{bitmap} is a 1 (i.e., @tt{(bitmap & 0x01
 << i == 1) != 0}), it will represent the fact that the
bucket i is occupied. We will lay out @tt{data} such that
its length is equal to the number of occurrences of 1 in the
binary representation of @tt{bitmap}. The ith index into
@tt{data} will be regarded as the bucket occupied by the
ith occurrence of 1 in the binary representation of @tt{
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
64th bit of @tt{bitmap} will be set.

To access Sam's record, we lookup position 63 in @tt{bitmap}
and check to see whether it is set to 1. If not, it will
signify that no record exists for Sam in this node. Assuming
it is, we then count the number of 1s @emph{below} position
64 in the bitmap. This operation is called @tt{popcount()}
(short for "population count," which counts the number of 1s
in a machine word), and built into many modern instruction
sets, so that it executes quite efficiently. We then use
@tt{popcount} of the part of @tt{bitmap} below the 63th bit
to index into @tt{data}.

By doing this, we reduce the amount of space stored for each
node from 64 to @tt{popcount(bitmap)}. In practice, this
means that we get good performance when the trie is sparse,
and when the trie is dense (i.e., most nodes hold close to
64 child elements) the performance is no worse than an
implementation without compression.

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
nodes are be implemented. At each depth in the HAMT, a node
handles a 6-bit piece of a 64-bit hash. In our
implementation, the root node (which we'll implement soon as
a class called @tt{hamt}) will hold 4 of those bits, while
the 60 remaining bits will be handled by a trie whose
maximum depth is 10. After depth 10, all values which would
share the same bucket also share the same hash, and so we
must devolve into an association list.

To do its work, each inner node in HAMT must know which
6-bit piece of the hash its working on. We could do this by
iteratively computing this value as we traverse down the
nodes, gradually moving from the first four bits (for the
top level node, which holds four bits), to the second six
bits, to the third six bits, etc... However, instead, we're
going to use template metaprogramming to generate a
template-specialized version of the node class for each
depth from 1 to 10, meaning that the C++ compiler will
generate @tt{KV<K,V,0>} through @tt{KV<K,V,9>} for us using
our template, and we will manually instantiate @tt{
 KV<K,V,10>} by hand to be our node implementation that uses
an association list. In essence, we have traded an addition
at @emph{runtime} for a specialization of the code at @emph{
 compile time}.

It's worth noting that we could do this without template
metaprogramming, but we would have to manually write out the
code to operate on each six bit sequence from 1 to 10
ourselves, which would be significantly messy.

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
  set the lowest bit of @tt{k} to 0. The upper bits of k will
  be a pointer to the key, which we can use on subsequent
  lookups. The reason we can do this is that pointers to keys
  will always be aligned, so that the lowest bit will never be
  zero. @tt{v} will then be a pointer to the value being
  stored. }

 @item{It's a node containing buckets. In this case, we will
  set the lowest bit of @tt{k} to 1. The rest of @tt{k} will
  be a bitmap containing 63 bits, and @tt{v} will serve the
  place of the @tt{data} array discussed in section
  @secref["compress"]}
 ]

The lowest level of our HAMT will be a key-value association
list, using the linked list we implemented in section
@secref["linkedlist"]:

@codeblock[#:line-numbers 1]|{
// A template-specialized version of KV<K,V,d> for the lowest depth of inner nodes, d==bd
// After this we have exhausted our 64 bit hash (4 bits used by the root and 6*10 bits used by inner nodes)
template <typename K, typename V>
class KV<K,V,bd>
{
    typedef LL<K,V> LLtype;
    typedef KV<K,V,bd> KVbottom;

public:
    // We use two unions and the following cheap tagging scheme:
    // when the lowest bit of Key k is 0, it's a key and a K*,V* pair (key and value),
    // when the lowest bit of Key k is 1, it's either a bm (bitmap) in the top 63 bits with a
    // KVnext* v inner node pointer when d is less than bd-1 or it's just a 1 and a pointer to a
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
    KVtop data[7];
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
    const u64 hpiece = (h & 0xf) % 7;

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

Internal nodes look at six bit sequences of the hash from
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

Note that we right shift the bitmap by one, because the
lowest bit will be set to zero or one based on the tagging
scheme discussed above. We use the @tt{__builtin_popcountll}
function to calculate @tt{popcount} in an efficient way. The
compiler will then either generate architecture-specific
instructions, or (if compiling for an architecture where
@tt{popcount} has not been implement) an optimized set of
assembly instructions to do so. We then use the result of
@tt{popcount} to look up the corresponding index in @tt{
 data}, and perform the lookup for the key-value pair or
again delegate to @tt{inner_find}.

@subsubsection{Lookup From an Association List}


@subsubsection{Lookup From an Association List}

@subsection{Inserting Into HAMT}

Inserting into a HAMT involes many of the same operations as
searching for a key-value pair. The main changes are to:

@itemlist[
 @item{Allocate memory for new pieces of the HAMT and copy
  pieces of the original HAMT.}
 @item{Break apart parts of the HAMT when collisions happen
  on parts of the hash to build the HAMT lazily as described in section @secref["lazy"].}
 ]

 