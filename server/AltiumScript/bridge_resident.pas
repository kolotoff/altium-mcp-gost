// Included only in the generated resident bridge.
const
    BridgeResidentKey = '{BRIDGE_RESIDENT_BUNDLE_KEY}';
    BridgeIdleMS = 10000;

function BridgeResidentToken: String;
var
    Ticket: TStringList;
    Token: String;
    I: Integer;
begin
    Result := '';
    if not FileExists(ROOT_DIR + 'bridge-resident.json') then Exit;
    Ticket := TStringList.Create;
    try
        Ticket.LoadFromFile(ROOT_DIR + 'bridge-resident.json');
        if RequestText(Ticket, 'bundle_key', '') <> BridgeResidentKey then Exit;
        Token := RequestText(Ticket, 'token', '');
        if Length(Token) <> 32 then Exit;
        for I := 1 to Length(Token) do
            if Pos(Token[I], '0123456789abcdef') = 0 then Exit;
        Result := Token;
    finally
        Ticket.Free;
    end;
end;

procedure RunResident;
var
    Token, LeasePath, ReadyPath, SettlingPath, SingleRequest: String;
    Ready: TStringList;
    LastTick, Tick: Double;
    Dispatched: Boolean;
begin
    InitializeFilePaths();
    Token := BridgeResidentToken;
    if Token = '' then Exit;
    SingleRequest := REQUEST_FILE;
    LeasePath := ROOT_DIR + 'bridge-resident-' + Token + '.lease';
    ReadyPath := ROOT_DIR + 'bridge-resident-' + Token + '.ready';
    SettlingPath := ROOT_DIR + 'bridge-resident-' + Token + '.settling';
    REQUEST_FILE := ROOT_DIR + 'bridge-resident-' + Token + '.request.json';
    if (not FileExists(LeasePath)) or FileExists(ReadyPath) then Exit;
    Ready := TStringList.Create;
    try
        Ready.SaveToFile(ReadyPath);
        LastTick := GetTickCount;
        while FileExists(LeasePath) and (not FileExists(SingleRequest)) do
        begin
            Dispatched := FileExists(REQUEST_FILE);
            if Dispatched then
            begin
                // Signal before dispatch can publish its response. Updates
                // queued by this command may take time to process afterward.
                Ready.SaveToFile(SettlingPath);
                DispatchBridgeRequest;
                LastTick := GetTickCount;
            end;
            Tick := GetTickCount;
            if (Tick < LastTick) or ((Tick - LastTick) >= BridgeIdleMS) then Break;
            // Process Windows messages only between requests. In particular
            // there is no re-entry into a PCB transaction through this loop.
            Application.ProcessMessages;
            if Dispatched then DeleteFile(SettlingPath);
            Sleep(40);
        end;
    finally
        Ready.Free;
        DeleteFile(LeasePath);
        DeleteFile(ReadyPath);
        DeleteFile(SettlingPath);
    end;
end;
