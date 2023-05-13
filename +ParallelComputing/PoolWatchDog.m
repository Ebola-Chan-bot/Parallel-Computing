classdef PoolWatchDog<handle
	%并行池看门狗，可以自动删除长时间卡死的并行池
	%有时，并行池会因为程序员无法控制的原因卡死。可以使用看门狗来监视并行池运行状况，并在卡死时删除并行池，释放资源。之所以叫看门狗，是想象有一条永远饥饿的狗，看守着主
	% 人放在它面前的食物。主人命令它不准偷吃，但它的忍耐能力是有限的，一旦过度饥饿就会忍不住将食物吃掉。主人只要定期用狗粮喂狗，使得看门狗不至于过度饥饿，就不会吃掉看
	% 守的食物。但是，如果主人出了意外，超过了一定期限没有来喂狗，狗就会按捺不住饥饿将食物吃掉。这里的主人就是可能会卡死的程序，食物就是程序所占据的资源：如果程序卡死
	% 没有及时喂狗，狗就会将程序所占据的资源强行释放掉，或者直接结束进程本身（食物就是主人本身，主人忘了喂狗的话自己就会被狗吃掉）。
	%# 示例
	% ```
	% %首先，指定一个秒数，这是看门狗每次被喂食以后最多能忍耐饥饿的时间长度
	% WatchDog=ParallelComputing.PoolWatchDog(4);
	% %启动并行池，将看门狗介绍给每个并行工人，要求他们定时喂狗。这里以spmd并行池为例，parfor和parfeval也同理：
	% try
	%	spmd
	%		for a=1:24
	%			fprintf('SPMD%u: 喂狗\n',PID);
	%			WatchDog.Feed;
	%			Seconds=rand*a;
	%			%这里用暂停来模拟工人要执行的任务，任务执行期间无法喂狗
	%			fprintf('SPMD%u: 暂停%.1f秒\n',PID,Seconds);
	%			pause(Seconds);
	%		end
	%	end
	%	%狗只有一条，每个并行工人都可以来喂。狗只要被任何一个工人喂过，就可以再忍耐指定秒数。但如果所有工人都忙于工作或者卡死，没能在指定秒数中来喂狗，狗就会删除当前并
	%	 行池，杀死所有工人。
	% catch ME
	% 	if ME.identifier=="MATLAB:class:InvalidHandle"
	%		%抛出此异常说明是被看门狗结束的
	%	else
	%		%否则是因为看门狗以外的原因结束
	%		ME.rethrow;
	% 	end
	% end
	% WatchDog.Stop;
	% %任务结束后，记得停用看门狗，这样会停止它的计时器，否则狗可能在意外的时刻突然删除并行池。停用的看门狗不必销毁，可以继续用于下次任务。
	% ```
	properties(GetAccess=private,SetAccess=immutable)
		DataQueue
	end
	properties(GetAccess=private,SetAccess=immutable,Transient)
		DogTimer
		Listener
	end
	methods(Access=private)
		function FeedCallback(obj,~)
			obj.DogTimer.stop;
			obj.DogTimer.start;
		end
	end
	methods
		function obj = PoolWatchDog(WatchSeconds)
			%请在主线程上构造对象，然后分发给并行工人。
			%# 语法
			% ```
			% obj=ParallelComputing.PoolWatchDog(WatchSeconds);
			% ```
			%# 输入参数
			% WatchSeconds(1,1)double，看门狗的忍耐秒数
			obj.DataQueue=parallel.pool.DataQueue;
			obj.Listener=obj.DataQueue.afterEach(@obj.FeedCallback);
			obj.DogTimer=timer(StartDelay=WatchSeconds,TimerFcn=@(~,~)delete(gcp('nocreate')));
		end
		function Feed(obj)
			%并行工人应当定时喂狗，证明自己没有卡死
			obj.DataQueue.send(missing);
		end
		function Stop(obj)
			%停用看门狗。
			%停用后的看门狗不会再删除当前并行池，但可以再次用于下次并行任务。
			obj.DogTimer=stop;
		end
		function delete(obj)
			delete(obj.DataQueue);
			delete(obj.DogTimer);
			delete(obj.Listener);
		end
	end
end