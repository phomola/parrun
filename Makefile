main: parrun.m
	clang parrun.m -o parrun -fobjc-arc -O3 -framework CoreServices -Wall
