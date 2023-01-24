classdef BlockRWStream<handle
	%为无法一次性全部读入内存的大文件，提供单线程读写、多线程计算的解决方案
	%处理大量数据时，经常遇到单个数据文件过大，无法一次性全部读入内存再处理的问题。此时只能先读入一个小数据块，计算处理后，输出结果，释放内存，再读入下一个。在单线程环
	% 境下，这是唯一的解决方案。
	%但在多线程环境下，我们往往发现，尽管中间计算过程受益于多线程得到了加速，但输入和输出的I/O过程，只能单线程执行：磁盘、网络等I/O设备并不会被多线程加速。即使在代码中
	% 指定为并行I/O，硬件上也不能真正做到并行，而仅仅是在多个线程之间不断切换实现的"伪并行"，更不用说这种切换还会产生额外的开销，总体性能还不如单线程。
	%因此我们认为，在多线程环境下的最优方案，是单线程读写、多线程计算。即设置一个服务线程，专门负责I/O等单线程操作，然后将数据分发到多个工作线程执行计算，计算结果再归
	% 并到服务线程执行写出操作。
	%MATLAB恰好提供了一个这样的线程模型，即主线程-并行计算模型。MATLAB的界面和一般的代码、命令行任务都在主线程中执行，但可以在代码中引入并行命令，如 spmd parfor
	% parfeval 等（依赖 Parallel Computing Toolbox），在并行线程上执行代码。
	%BlockRWStream在此基础上建立了一个框架，以支持在主线程上执行对文件的分块I/O操作，在并行线程上执行计算。其中复杂的线程同步、数据分发和收集问题，都被封装起来，对用
	% 户透明。用户只需要关心数据的具体读写操作和处理过程。
	%请注意，并行线程并非多多益善，而是存在一个最优数目，为数据计算时间与I/O时间之比，向上取整。例如，读入一个数据块需要1min，处理这些数据需要5min，写出计算结果又需要
	% 1min，那么最优的线程配置方案就是ceil(5/(1+1))=3个计算线程，加上1个I/O主线程，共4个线程。过多的计算线程只会长期处于等待主线程I/O的状态，并不能缩短总的工作时间，
	% 反而占用额外的内存。特别地，如果计算时间比I/O时间还要短，那么1个I/O线程+1个计算线程共2个线程的方案就已经达到最优。具体的方案因硬件和任务而异，需要用户手动设置，
	% BlockRWStream只会按照当前设置安排并行。在不知道具体的计算时间与I/O时间之比时，可以通过试验测定。线程数达到最优的判定标准是，在保证I/O线程稳定处于满负荷工作状态
	% 条件下，并行线程数尽可能少。用户可以使用ParallelComputing.SetParpool轻松设置并行线程个数，更复杂的设置则需参考parpool文档。
	%
	%下面给出一个示例。该示例执行的任务是，读入一批庞大的视频文件，将每个视频的所有帧叠加取平均，得到平均帧图，每个视频输出一张图。
	%第一步，实现ParallelComputing.IBlockRWer抽象接口类，定义视频读入过程。此代码在ParallelComputing.IBlockRWer的文档中展示，此处不再赘述。
	%第二步，定义BatchVideoMean函数，利用BlockRWStream实现视频批量平均图操作：
	%```
	%function BatchVideoMean(VideoPaths)
	% %BlockVideoReader是实现了ParallelComputing.IBlockRWer的具体类。将它的构造函数句柄交给BlockRWStream构造函数，得到的对象执行SpmdRun方法，对每个数据块返回其全帧
	% 总和和帧数。数据块可以在GPU上执行计算，返回2个元胞。计算过程将占用2倍于数据块大小的内存。
	%CollectData=ParallelComputing.BlockRWStream(VideoPaths,@BlockVideoReader).SpmdRun(@(Data){sum(Data,4),size(Data,4)},NArgOut=1,NumGpuArguments=1,...
	% RuntimeCost=2);
	% %返回的CollectData包含了所有文件所有数据块的全帧总和和帧数。
	%[Directories,Filenames]=fileparts(VideoPaths);
	%OutputPaths=fullfile(Directories,Filenames+".平均.png");
	% %将在每个视频文件的同目录下生成一个平均帧PNG图像。
	%for V=1:numel(CollectData)
	%	Data=vertcat(CollectData{V}{:});
	%	Data=vertcat(Data{:});
	%	%将每个文件的数据块归并，计算全帧平均，写出PNG图像。
	%	imwrite(uint8(sum(cat(4,Data{:,1}))/sum([Data{:,2}])),OutputPaths(V));
	%end
	%```
	%此示例中，数据块的计算操作实际上只有一个求和和求尺寸，非常快，一般不会比读入时间更长，所以只需1个计算线程+1个I/O线程就足够了。调用此函数BatchVideoMean之前可以使
	% 用ParallelComputing.SetParpool(1)以设置只使用1个计算线程。
	%
	%BlockRWStream的所有方法均支持子类继承重写。您可以在理解其工作原理的基础上按需更改其行为。在ParallelComputing.BlockRWStream.NextObject文档中提供了一个示例，该示
	% 例重写NewObject函数，以实现每次读取新文件时输出进度信息。
	%本类的属性一般作调试信息用，监视进度和状态，不应手动修改。
	%多数情况下，您只需实现IBlockRWer、构造BlockRWStream对象、调用ParallelComputing.BlockRWStream.SpmdRun方法即可完成工作流。如果您需要更自定义地控制工作流，可以自
	% 行建立并行框架，然后调用BlockRWStream下的 Local/Remote Read/Write Block 方法，进行自定义的本地/远程读写操作。SpmdRun本质上也是通过调用这些方法实现的。SpmdRun
	% 方法的文档中展示了工作流的细节，建议参考。
	%此类对象的使用是一次性的。一旦所有文件读取完毕，对象就会报废，无法重复使用，必须新建。
	%See also ParallelComputing.SetParpool parpool ParallelComputing.IBlockRWer ParallelComputing.BlockRWStream.SpmdRun
	
	%% 通信
	properties(SetAccess=immutable,GetAccess=private,Hidden)
		RequestQueue parallel.pool.DataQueue
	end
	%% 本地
	properties(SetAccess=immutable,Transient)
		%输入的文件列表，依次作为GetRWer的参数以获取读写器。
		RWObjects
		%文件个数
		NumObjects
		%获取读写器的函数句柄，通常是读写器的构造函数
		GetRWer
	end
	properties(SetAccess=private,Transient)
		%已经读完的文件个数
		ObjectsRead=0
		%当前文件已经读完的数据片个数
		PiecesRead
		%已经读完的数据块总数
		BlocksRead=0
		%维护每个数据块的信息表
		BlockTable=table('Size',[0,4],'VariableTypes',["uint16","uint32","uint32","cell"],'VariableNames',["ObjectIndex","StartPiece","EndPiece","ReturnData"])
		%维护每个文件的信息表
		ObjectTable
	end
	methods(Access=protected)
		function NextObject(obj)
			%打开新的文件以供读取。此方法只有在BlockRWStream刚刚构建完毕，以及上一个文件读取完毕后才被内部调用。但需要检查是否所有文件已经读完。
			%此方法没有输入输出，仅设置类内部各属性的状态。此方法标志着上一个文件读入完毕、下一个文件开始读入，因此可以重写它以输出进度信息。如下示例：
			%```
			%classdef ShowProgress<ParallelComputing.BlockRWStream
			%	methods(Access=protected)
			%		function NextObject(obj)
			%			%先调用基类，执行该方法必要的基本功能
			%			obj.NextObject@ParallelComputing.BlockRWStream;
			%			%然后输出进度
			%			Index=obj.ObjectsRead+1;
			%			fprintf('文件%u/%u：%s\n',Index,obj.NumObjects,obj.RWObjects(Index));
			%		end
			%	end
			%	methods
			%		function obj=ShowProgress(RWObjects,GetRWer)
			%			obj@ParallelComputing.BlockRWStream(RWObjects,GetRWer);
			%		end
			%	end
			%end
			%```
			Index=obj.ObjectsRead+1;
			if Index<=obj.NumObjects
				obj.PiecesRead=0;
				RWer=obj.GetRWer(obj.RWObjects(Index));
				obj.ObjectTable(Index,1:2)={{RWer.CollectData},{RWer}};
			end
		end
		function ToCollect=WriteReturn(~,Data,StartPiece,EndPiece,Writer)
			%支持自定义重写，决定如何处理LocalWriteBlock数据
			%有时，输出的数据是一些统计类的数据，如求和，这些数据如果单纯堆积在内存中，是不必要的内存占用。子类可以重写此方法，用自定义方式处理
			% Local/Remote WriteBlock写出的数据，例如对数据进行求和，然后将和保存在子类自己的属性中，只返回那些必须堆积在内存中的数据供基类收集。
			%如果不重写此函数，默认将把数据直接交给Writer.Write方法写出，然后返回该方法的返回值。
			%# 重写语法
			% ```
			% function Tags=WriteReturn(obj,Data,StartPiece,EndPiece,Writer)
			% end
			% ```
			%# 重写示例
			% ```
			% function Tags=WriteReturn(obj,Data,StartPiece,EndPiece,Writer)
			%	[Data,Tags,RSum,RSquareSum,RSizeT]=Data{:};
			%	%Data就是LocalWriteBlock写入的Data参数，其数据格式是用户定义的。此处示例数据是cell(1,5)类型，包装了5个数据子项。其中，Tags子项要返回给基类进行收集。
			%
			%	%Data子项要写出到文件，并指定起始和结束数据片范围。
			%	Writer.Write(Data,StartPiece,EndPiece);
			%
			%	%RSum RSquareSum SizeT 这三个子项要求和，结果存放在子类自定义的属性中。求和过程有效节约了内存，防止了大量分块积累造成内存不足。
			%	obj.Sum=obj.Sum+RSum;
			%	obj.SquareSum=obj.SquareSum+RSquareSum;
			%	obj.SizeT=obj.SizeT+RSizeT;
			% end
			% ```
			%# 输入参数
			% obj(1,1)BlockRWStream，类对象实例本身
			% Data，从 Local/Remote WriteBlock 传来的数据，数据类型格式由调用时用户指定。这些数据通常应作为块处理函数的返回值供输出。如果您使用BlockRWStream.SpmdRun
			%  方法，此参数必定是元胞行向量，每个元胞内存放一个SpmdRun.BlockProcess参数的返回值。即使BlockProcess只有1个返回值，SpmdRun也会将它包装在元胞中。
			% StartPiece(1,1)uint32，首数据片
			% EndPiece(1,1)uint32，尾数据片
			% Writer(1,1)IBlockRWer，用户定义的读写器对象，用于写出数据。应当实现Write方法。
			%# 返回值
			% ToCollect，要返回给基类收集的数据。这些数据将被CollectReturn方法返回。
			%See also ParallelComputing.IBlockRWer ParallelComputing.BlockRWStream
			ToCollect=Writer.Write(Data,StartPiece,EndPiece);
		end
	end
	methods
		function obj = BlockRWStream(RWObjects,GetRWer)
			%构造方法。需要提供文件列表和获取读写器的函数句柄。
			%# 语法
			% obj=ParallelComputing.BlockRWStream(RWObjects,GetRWer);
			%# 输入参数
			% RWObjects(:,1)，文件列表。本质上是要交给GetRWer的参数，因此该参数具体内容由GetRWer决定。每次打开新文件，会将RWObjects的一个元素交给GetRWer以获取读写
			% 器。可以用元胞包含复杂参数，或者继承此类以实现更复杂的构造。
			% GetRWer，用于获取读写器的函数句柄。该句柄必须只接受一个标量参数，输出一个ParallelComputing.IBlockRWer对象。
			%See also ParallelComputing.IBlockRWer
			import parallel.pool.*
			obj.RWObjects=RWObjects;
			obj.NumObjects=numel(RWObjects);
			obj.GetRWer=GetRWer;
			obj.RequestQueue=DataQueue;
			obj.RequestQueue.afterEach(@(Request)obj.(Request{1})(Request{2:end}));
			obj.ObjectTable=table('Size',[obj.NumObjects,4],'VariableTypes',["cell","cell","uint16","uint16"],'VariableNames',["Metadata","RWer","BlocksRead","BlocksWritten"]);
			obj.NextObject;
		end
		function LocalWriteBlock(obj,Data,BlockIndex)
			%在单线程环境下，写出一个数据块。
			%此方法只能在构造该对象的进程上调用，多线程环境下则会发生争用，因此通常用于单线程环境，退化为读入-计算-写出的简单流程。
			%# 语法
			% obj.LocalWriteBlock(Data,BlockIndex)
			%# 输入参数
			% Data，数据块处理后的计算结果。可以用元胞数组包含多个复杂的结果。此参数将被直接交给读写器的Write方法。
			% BlockIndex，数据块的唯一标识符，从LocalReadBlock获取，以确保读入数据块和返回计算结果一一对应。
			%See also ParallelComputing.BlockRWStream.LocalReadBlock
			ObjectIndex=obj.BlockTable.ObjectIndex(BlockIndex);
			Writer=obj.ObjectTable.RWer{ObjectIndex};
			obj.BlockTable.ReturnData{BlockIndex}=obj.WriteReturn(Data,obj.BlockTable.StartPiece(BlockIndex),obj.BlockTable.EndPiece(BlockIndex),Writer);
			BlocksWritten=obj.ObjectTable.BlocksWritten(ObjectIndex)+1;
			if BlocksWritten==obj.ObjectTable.BlocksRead(ObjectIndex)&&obj.ObjectsRead>=ObjectIndex
				delete(Writer);
			end
			obj.ObjectTable.BlocksWritten(ObjectIndex)=BlocksWritten;
		end
		function [CollectData,Metadata]=CollectReturn(obj)
			%所有计算线程结束后，由主线程调用此方法，收集返回的计算结果。
			%# 返回值
			% CollectData，一个元胞列向量，每个元胞对应一个文件的计算结果。元胞内又是元胞列向量，每个元胞对应一个数据块的计算结果，即计算线程每次调用Local/Remote
			%  WriteBlock时提供的Data参数，经过WriteReturn方法处理后的返回值。如果使用SpmdRun，每个数据块的计算结果将是一个元胞行向量，对应计算函数的每个返回值。例
			%  如，如果返回m×1元胞列向量，说明输入的文件有m个；其中第a个元胞内是n×1元胞列向量，说明第a个文件被分成了n块读入；其中第b个元胞内是1×p元胞行向量，说明可能
			%  是用了SpmdRun且计算函数有p个返回值。
			% Metadata，每个文件的元数据，为每个IBlockRWer的Metadata属性值，排列在元胞列向量中。
			%See also ParallelComputing.BlockRWStream ParallelComputing.IBlockRWer.Metadata
			BlockIndex=1:obj.BlocksRead;
			CollectData=splitapply(@(RD){RD},obj.BlockTable.ReturnData(BlockIndex),obj.BlockTable.ObjectIndex(BlockIndex));
			Metadata=obj.ObjectTable.Metadata;
		end
	end
	%% 远程
	methods
		function IPollable=RemoteReadAsync(obj,varargin)
			%在计算线程上，向I/O线程异步请求读入一个数据块。异步请求不会等待，而是先返回继续执行别的代码，等需要数据时再提取结果。
			%此方法可以在并行计算线程（parfor spmd parfeval 等）上调用，但会在I/O主线程上执行读入操作，然后将数据返回给计算线程。主线程上实际执行的是LocalReadBlock。
			%# 语法
			% 本方法输入参数实际上和LocalReadBlock相同。返回值则是一个可等待对象，用于异步接收LocalReadBlock的返回值。
			% ```
			% IPollable=obj.RemoteReadBlock(ReadSize=ReadSize);
			% IPollable=obj.RemoteReadBlock(ReadBytes=ReadBytes);
			% IPollable=obj.RemoteReadBlock(___,LastObjectIndex=LastObjectIndex);
			% ``
			%# 示例
			% 此示例与LocalReadBlock的示例类似，但展现了异步工作流，使得I/O和数据处理得以并行执行。
			% ```
			% function Example(obj,Memory,BlockProcess)
			% ObjectIndex=0;
			%
			% ArgOuts=obj.RemoteReadAsync(ReadSize=Memory,LastObjectIndex=ObjectIndex).poll(Inf);
			% %首次调用直接poll取得返回值
			%
			% if ArgOuts{1}~=ParallelComputing.ParallelException.Operation_succeeded
			%	%返回元胞数组第1个值指示是否发生异常，后面才是主线程执行LocalReadBlock的返回值
			%	ArgOuts{1}.Throw;
			% end
			% [Data,BlockIndex,NewOI,NewOD]=ArgOuts{2:end};
			% while ~ismissing(Data)
			%
			%	IPollable=obj.RemoteReadAsync(ReadSize=Memory,LastObjectIndex=ObjectIndex);
			%	%注意此时尚未处理刚刚读到的数据就可以直接请求下一块数据，此请求可以不等待数据实际读完就立刻返回IPollable对象。这样接下来可以不必等待主线程忙于读入数据
			%	% 的时间，利用这段时间处理上次读入的数据块。
			%
			%	if NewOI>ObjectIndex
			%		ObjectIndex=NewOI;
			%		ObjectData=NewOD;
			%	end
			%	varargout=cell(1,nargout);
			%
			%	[varargout{:}]=BlockProcess(Data{:},ObjectData{:});
			%	%这一步执行数据处理，耗时较长，但主线程的数据读入也在同时进行，因而时间和硬件性能得到了充分发挥
			%
			%	obj.RemoteWriteBlock(varargout,BlockIndex);
			%	%远程请求异步写出数据，此方法也是立即返回，不必等待数据实际写出到文件。
			%	%上一块计算完毕，我们再来poll，取得之前异步请求读入的下一块数据。如果数据在计算结束之前就已经读完，这一步可以立即返回新的数据块。
			%	ArgOuts=IPollable.poll(Inf);
			%	if ArgOuts{1}~=ParallelComputing.ParallelException.Operation_succeeded
			%		%返回元胞数组第1个值指示是否发生异常，后面才是主线程执行LocalReadBlock的返回值
			%		ArgOuts{1}.Throw;
			%	end
			%	[Data,BlockIndex,NewOI,NewOD]=ArgOuts{2:end};
			% end
			%```
			%# 输入参数
			% 本方法远程调用LocalReadBlock，参数与之相同，不再赘述。
			%# 返回值
			% IPollable(1,1)parallel.pool.PollableDataQueue，可等待的数据队列。此方法立即返回，不等待数据读入完毕，可以异步执行其它任务。需要数据时，调用其poll方法
			%  可以取得数据。poll将返回元胞行向量，第一个元胞内是ParallelException异常枚举，如果是ParallelException.Operation_succeeded说明操作成功，否则操作失败。
			%  如果操作成功，后续元胞内依次排列LocalReadBlock的各个返回值。
			%See also ParallelComputing.BlockRWStream.LocalReadBlock parallel.pool.PollableDataQueue.poll ParallelComputing.ParallelException
			IPollable=parallel.pool.PollableDataQueue;
			obj.RequestQueue.send([{'LocalReadBlock',IPollable},varargin]);
		end
		function varargout=RemoteReadBlock(obj,varargin)
			%在计算线程上，向I/O线程请求读入一个数据块
			%此方法可以在并行计算线程（parfor spmd parfeval 等）上调用，但会在I/O主线程上执行读入操作，然后将数据返回给计算线程。主线程上实际执行的是LocalReadBlock。
			% 因此，此方法的输入参数和返回值与LocalReadBlock完全相同。此处不再赘述。
			%See also ParallelComputing.BlockRWStream.LocalReadBlock
			varargout=obj.RemoteReadAsync(varargin{:}).poll(Inf);
			if numel(varargout)==1
				varargout{1}.Throw;
			end
		end
		function RemoteWriteBlock(obj,Data,Index)
			%在计算线程上，向I/O线程请求写出一个数据块
			%此方法可以在并行计算线程（parfor spmd parfeval 等）上调用，但会在I/O主线程上执行写出操作。计算线程在发出请求后不会等待操作完成，而是继续向下运行。主线程
			% 上实际执行的是LocalWriteBlock。因此，此方法的输入参数与LocalWriteBlock完全相同。此处不再赘述。
			%See also ParallelComputing.BlockRWStream.LocalWriteBlock
			obj.RequestQueue.send({'LocalWriteBlock',Data,Index});
		end
	end
end