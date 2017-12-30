GC = /usr/local/lib/libgc.a # On mac, ../bdwgc/gc.a

test_hamt:
	g++ --std=c++11 -pthread -o3 -Wall -I ../bdwgc/include/ -o test_hamt test_hamt.cpp $(GC)

debug:
	g++ --std=c++11 -pthread -g -Wall -I ../bdwgc/include/ -o test_hamt test_hamt.cpp $(GC)

clean:
	rm *.o test_hamt *#* *~* 
