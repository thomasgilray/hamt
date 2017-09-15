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

The association list uses sharing to acheive both constant
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
logarthmic runtimes and offer efficient persistence by
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

@subsection{From trees to tries}

Turning our sorted tree into a hash-tree doesn't buy us any
performance improvement, but it helps us make our way
towards exploiting some of the unique properties of the
hash-tree.

One useful observation we can make is that hashes can be
ordered simply into prefixes:

@(cimgn "images/prefixnums.png")

