






test_hamt:
	g++ --std=c++11 -pthread -o3 -Wall -I ../bdwgc/include/ -o test_hamt test_hamt.cpp /usr/local/lib/libgc.a

debug:
	g++ --std=c++11 -pthread -g -Wall -I ../bdwgc/include/ -o test_hamt test_hamt.cpp /usr/local/lib/libgc.a

clean:
	rm *.o test_hamt *#* *~* 


