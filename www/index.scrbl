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
Association lists are linked lists made up of key-value
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

@subsection{Implementing association lists}

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

@subsection{Worst case beahvior}

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

@subsubsection{A few optimizations}

Our trie now avoids the worst-case behavior we observed with
a sorted binary tree, which appears better in theory, but
has a few undesirable traits in practice:

@itemlist[
 @item{A maximum depth of 64 is still quite a large tree to traverse in the worst-case}
 @item{In the case that the map is relatively sparse--i.e.,
  that it doesn't contain many key-value pairs, we are still
  required to traverse all the way down to the leaf just to lookup one key-value pair.}
 ]

@centered{@bold{Reducing the Height}}

To solve the first problem, we can simply switch from a
binary tree to an n-ary tree: in our case, we're going to
hold 64 "buckets" at each node, rather than 2. By doing
this, we'll lower the maximum depth of our tree to be 10.
Instead of each node deciding whether a bit will be a 0 or a
1, each node will decide whether the next 6 bits of the hash
are @tt{0x00} to @tt{0x3F}:

@(cimgn "images/buckets.png")

So now our trie will have a structure like this:

@(cimgn "images/fullbuckets.png")

@centered{@bold{Store the Key-Value Pair When Possible}}

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

@centered{@bold{Reducing Wasted Memory}}

When the trie is relatively sparse, assigning 64 buckets to
each node is inefficient in terms of both space (occupied by
each node) and time (spent copying memory to allocate new
nodes).

To solve this problem, we'll use a bitmap. Instead of each
node holding 64 buckets, a node will hold a single 64 bit
value, @tt{bitmap}, with an array of buckets, @tt{data}.
Then, if position i in @tt{bitmap} is set, it will represent
the fact that bucket i is occupied (non-null). Then, we will
make @tt{data} an array whose length is equal to the number
of 1s in @tt{bitmap}. The ith index into @tt{data} will be
regarded as the bucket occuppied by the ith occurrence of 1
in @tt{bitmap}.

This is quite tricky, so here's a picture:

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
 bitmap} will be set to 1. Similarly, because Sam's record
occupied position @tt{0x3F} in the old representation, the
64th bit of @tt{bitmap} will be set.

To access Sam's record, we would go to position 64 in the
bitmap and check to see that it was set to 1. If it is not,
no record would exist for Sam in this node. Assuming it is,
we then count the number of 1s @emph{below} position 64 in
the bitmap. This operation is called @tt{popcount} (short
for "population count," which counts the number of 1s in a
machine word), and built into many modern instruction sets.
We then use @tt{popcount} to index into @tt{data}.

By doing this, we reduce the amount of space stored for each
node from 64 to @tt{popcount}.

@section{Implementing HAMT}

