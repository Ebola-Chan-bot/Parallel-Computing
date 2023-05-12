classdef PoolWatchDog<handle
	%监控工作进程，如果超时没有喂狗，强行终止进程
	properties(GetAccess=private,SetAccess=immutable)
		DataQueue
	end
	properties(GetAccess=private,SetAccess=immutable,Transient)
		DogTimer
		Listener
	end
	methods(Access=private,Static)
		function FeedCallback(~)
			obj.DogTimer.stop;
			obj.DogTimer.start;
		end
	end
	methods
		function obj = PoolWatchDog(WatchSeconds)
			%在主进程上构造对象，然后分发给工作进程。指定判断进程已死的等待秒数。
			obj.DataQueue=parallel.pool.DataQueue;
			obj.Listener=obj.DataQueue.afterEach(@ParallelComputing.PoolWatchDog.FeedCallback);
			obj.DogTimer=timer(StartDelay=WatchSeconds,TimerFcn=@(~,~)delete(gcp));
		end
		function Feed(obj)
			%工作进程应当定时喂狗，证明自己没有卡死
			obj.DataQueue.send(missing);
		end
		function delete(obj)
			delete(obj.DataQueue);
			delete(obj.DogTimer);
			delete(obj.Listener);
		end
	end
end