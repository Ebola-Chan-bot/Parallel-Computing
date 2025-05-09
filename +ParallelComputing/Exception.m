classdef Exception<MATLAB.Lang.IEnumerableException
	enumeration
		Operation_succeeded
		ReadSize_is_smaller_than_IBlockRWer_PieceSize
		All_objects_have_been_read
		Can_only_specify_ReadBytes_xor_ReadPieces
		ReadBytes_xor_ReadPieces_must_specify_one
		WatchDogSeconds_deprecated
	end
end